import os
import AVFoundation
import Foundation

/// The capture → resample → socket hop, which is the one part of the subtitle
/// pipeline that never touches the main actor.
///
/// Split out of `SubtitleModel` because it is the half with entirely different
/// rules: the IO thread only publishes into a preallocated lock-free ring;
/// conversion, metrics, logging and network work happen on its worker. Keeping
/// it beside the observable state invited edits written for the main actor.
extension SubtitleModel {
    /// The client and lazily-built resampler, confined to the worker queue.
    ///
    /// Internal rather than private for the same reason as `Defaults`: the
    /// model that owns it is now in another file.
    nonisolated final class AudioPath: @unchecked Sendable {
        private let direction: Direction
        private var client: TranslationClient?
        private var resampler: Resampler?
        private let queue: RealtimeAudioQueue
        private let callback: Callback

        private final class Callback: @unchecked Sendable {
            weak var owner: AudioPath?
        }

        init(direction: Direction) {
            self.direction = direction
            let callback = Callback()
            self.callback = callback
            queue = RealtimeAudioQueue(
                label: "app.livetranslate.audio.\(direction.rawValue)"
            ) { [weak callback] buffer in
                callback?.owner?.process(buffer)
            } onDrop: { [weak callback] count in
                callback?.owner?.report(
                    dropped: "realtime queue full or unsupported (\(count) buffers)"
                )
            }
            callback.owner = self
        }

        func install(client: TranslationClient?) {
            queue.perform { [weak self] in
                guard let self else { return }
                self.client = client
                if client == nil { self.resampler = nil }
            }
        }

        @available(macOS 14.2, *)
        func enqueue(_ buffer: DownlinkTap.Buffer) { queue.enqueue(buffer) }

        func enqueue(_ buffer: AVAudioPCMBuffer) { queue.enqueue(buffer) }

        private func process(_ buffer: AVAudioPCMBuffer) {
            if resampler == nil {
                resampler = try? Resampler(sourceFormat: buffer.format)
                if resampler == nil { BridgeLog.audio.error("resampler could not be built") }
            }
            guard let resampler else { return }
            guard let client else {
                report(dropped: "no client installed")
                return
            }
            guard let pcm = try? resampler.convert(buffer), !pcm.isEmpty else {
                report(dropped: "conversion produced no bytes")
                return
            }
            send(pcm, to: client)
            report(sent: pcm)
        }

        /// Hands the converted PCM to the socket in chunks no longer than
        /// `Self.chunkBytes`.
        ///
        /// The microphone arrives in 100 ms buffers — the floor the tap API
        /// allows — and appending one whole is a tenth of a second the
        /// service cannot see the end of the utterance in, because the bytes
        /// that would show it silent are still on this side. Splitting costs
        /// nothing: the same bytes go out, the socket already serialises its
        /// sends, and the service's own guidance is chunks in this range.
        ///
        /// A buffer shorter than the chunk — which is every buffer on the
        /// tap side, at ~10 ms — is sent as it came, so the common path adds
        /// no copy at all.
        private func send(_ pcm: Data, to client: TranslationClient) {
            guard pcm.count > Self.chunkBytes else {
                client.sendAudio(pcm)
                return
            }
            var start = pcm.startIndex
            while start < pcm.endIndex {
                let end = pcm.index(
                    start, offsetBy: Self.chunkBytes, limitedBy: pcm.endIndex
                ) ?? pcm.endIndex
                // A standalone `Data`, not a slice: a chunk held back behind
                // the handshake or across a reconnect would otherwise keep
                // the whole source buffer alive for as long as it is queued.
                client.sendAudio(Data(pcm[start..<end]))
                start = end
            }
        }

        /// 40 ms of 16 kHz mono Int16 — the long end of the range the service
        /// recommends per append, so the split stays coarse enough not to
        /// multiply frames while still bounding how stale the tail can be.
        private static let chunkBytes = Int(Resampler.targetSampleRate)
            / 25 * MemoryLayout<Int16>.size

        /// One line a second rather than one per buffer: at 48 kHz the IO
        /// thread can publish hundreds of times a second, and logging each one
        /// would flood the log and starve the worker.
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

            sentBuffers += 1
            sentBytes += pcm.count
            peakSample = max(peakSample, peak)
            // `ContinuousClock` rather than `Date`: this is elapsed time and
            // wall-clock adjustments must not stall or spam the line.
            let now = ContinuousClock.now
            guard !didReport || now - lastReport >= .seconds(1) else {
                return
            }
            didReport = true
            let buffers = sentBuffers, bytes = sentBytes
            let loudest = peakSample
            lastReport = now
            sentBuffers = 0
            sentBytes = 0
            peakSample = 0

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
            let now = ContinuousClock.now
            guard !didReport || now - lastReport >= .seconds(1) else {
                return
            }
            didReport = true
            lastReport = now
            BridgeLog.audio.error(
                "[\(self.direction.rawValue, privacy: .public)] dropping tap audio: \(reason, privacy: .public)"
            )
        }
    }
}
