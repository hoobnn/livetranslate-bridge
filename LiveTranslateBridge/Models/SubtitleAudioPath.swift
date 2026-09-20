import os
import AVFoundation
import Foundation

/// The capture → resample → socket hop, which is the one part of the subtitle
/// pipeline that never touches the main actor.
///
/// Split out of `SubtitleModel` because it is the half with entirely different
/// rules: everything here runs on a Core Audio IO thread, where a lock is held
/// for as short a span as possible and an allocation is a latency bug. Keeping
/// it beside the observable state invited edits written for the main actor.
extension SubtitleModel {
    /// The client and the lazily-built resampler, shared with the IO thread.
    ///
    /// Internal rather than private for the same reason as `Defaults`: the
    /// model that owns it is now in another file.
    nonisolated final class AudioPath: @unchecked Sendable {
        private let lock = NSLock()
        private let direction: Direction
        private var client: TranslationClient?
        private var resampler: Resampler?

        init(direction: Direction) {
            self.direction = direction
        }

        func install(client: TranslationClient?) {
            lock.lock(); defer { lock.unlock() }
            self.client = client
            if client == nil { resampler = nil }
        }

        /// The tap's format is only known once audio flows, so the resampler is
        /// built on the first buffer and reused afterwards.
        func send(_ makeData: (Resampler) -> Data?, sourceFormat: () -> AVAudioFormat?) {
            lock.lock()
            if resampler == nil, let format = sourceFormat() {
                resampler = try? Resampler(sourceFormat: format)
                if resampler == nil {
                    BridgeLog.audio.error("resampler could not be built")
                }
            }
            let converter = resampler
            let target = client
            lock.unlock()

            guard let converter else { return }
            guard let target else {
                report(dropped: "no client installed")
                return
            }
            guard let pcm = makeData(converter), !pcm.isEmpty else {
                report(dropped: "conversion produced no bytes")
                return
            }
            target.sendAudio(pcm)
            report(sent: pcm)
        }

        /// One line a second rather than one per buffer: at 48 kHz the IO
        /// thread arrives hundreds of times a second, and logging each one
        /// would both flood the log and stall a realtime thread.
        private var sentBuffers = 0
        private var peakSample = 0
        private var sentBytes = 0
        private var lastReport: ContinuousClock.Instant = .now

        /// Set on the first report so the opening line is not suppressed by a
        /// clock that starts "already a second ago".
        private var didReport = false

        private func report(sent pcm: Data) {
            // Byte count alone cannot tell a live call from digital silence,
            // and silence is indistinguishable from a broken tap at the
            // server: VAD simply never fires. Track the peak so the log says
            // which one this is.
            //
            // Strided rather than exhaustive: this runs on the Core Audio IO
            // thread for every buffer, and the peak is only ever read back as
            // a log line saying "live call" or "digital silence". Every 16th
            // sample at 16 kHz is still a thousand points a second — far more
            // than that distinction needs — for a sixteenth of the work.
            let peak = pcm.withUnsafeBytes { raw -> Int in
                let samples = raw.bindMemory(to: Int16.self)
                var loudest: Int32 = 0
                for index in stride(from: 0, to: samples.count, by: 16) {
                    // `Int32` because `abs(Int16.min)` overflows Int16.
                    let magnitude = abs(Int32(samples[index]))
                    if magnitude > loudest { loudest = magnitude }
                }
                return Int(loudest)
            }

            lock.lock()
            sentBuffers += 1
            sentBytes += pcm.count
            peakSample = max(peakSample, peak)
            // `ContinuousClock` rather than `Date`: this is an elapsed-time
            // question asked on a realtime thread, and `Date` both costs a
            // wall-clock read and can jump when the system clock is adjusted,
            // which would stall or spam the line for as long as the jump.
            let now = ContinuousClock.now
            guard !didReport || now - lastReport >= .seconds(1) else {
                lock.unlock()
                return
            }
            didReport = true
            let buffers = sentBuffers, bytes = sentBytes
            let loudest = peakSample
            lastReport = now
            sentBuffers = 0
            sentBytes = 0
            peakSample = 0
            lock.unlock()

            // Int16 full scale is 32767; the service's default VAD threshold
            // of 0.2 sits near 6553.
            let dbfs = loudest > 0
                ? 20 * log10(Double(loudest) / 32767.0) : -Double.infinity
            let side = direction.rawValue
            BridgeLog.audio.notice(
                "[\(side, privacy: .public)] peak \(loudest, privacy: .public) (\(String(format: "%.1f", dbfs), privacy: .public) dBFS)\(loudest < 1000 ? " — near silence, VAD will not fire" : "", privacy: .public)"
            )
            // "handed to the client", not "sent": the client may still be
            // queueing these behind an unfinished handshake.
            BridgeLog.audio.info(
                "[\(side, privacy: .public)] resampled \(buffers, privacy: .public) buffers / \(bytes, privacy: .public) bytes of 16k PCM in the last second"
            )
        }

        private func report(dropped reason: String) {
            lock.lock()
            let now = ContinuousClock.now
            guard !didReport || now - lastReport >= .seconds(1) else {
                lock.unlock()
                return
            }
            didReport = true
            lastReport = now
            lock.unlock()
            BridgeLog.audio.error(
                "[\(self.direction.rawValue, privacy: .public)] dropping tap audio: \(reason, privacy: .public)"
            )
        }
    }
}
