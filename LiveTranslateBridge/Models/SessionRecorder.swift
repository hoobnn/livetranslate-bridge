import os
import AVFoundation
import Foundation

/// Keeps a session's audio as AAC files beside its JSON, one per track:
/// what each side said and the translated speech played for it.
///
/// The originals are fed the 16 kHz mono PCM the audio path has already
/// converted for upload, before the silence gate; the translations the
/// service's 24 kHz mono speech as it is queued for playback, after
/// `ResponseAudioRouter` has put overlapping responses in order.
///
/// Every track shares one timeline, starting with the first sound any of
/// them hears. Capture opens long before that — while waiting for the call,
/// or for a permission prompt — and a microphone or loopback device
/// delivers digital silence all the while; none of it is kept. After that,
/// a stretch with no audio — a paused tap, a reopened route, the quiet
/// between two translated replies — is written as silence, so the files
/// line up and can be laid over each other.
///
/// Files open on the first audio of their track after that, so a track
/// that never sounds leaves no empty file behind. Writing and encoding run on a queue
/// of their own: callers only hand the bytes over.
nonisolated final class SessionRecorder: @unchecked Sendable {
    enum Track: String, CaseIterable, Sendable {
        case remote
        case local
        case remoteTranslation = "remote-translation"
        case localTranslation = "local-translation"

        static func original(_ direction: SubtitleModel.Direction) -> Track {
            direction == .remote ? .remote : .local
        }

        static func translation(_ direction: SubtitleModel.Direction) -> Track {
            direction == .remote ? .remoteTranslation : .localTranslation
        }

        var sampleRate: Double {
            switch self {
            case .remote, .local: Resampler.targetSampleRate
            case .remoteTranslation, .localTranslation: TranslationPlayer.translationRate
            }
        }
    }

    let id: UUID
    private let directory: URL
    /// When the first sound arrived, on any track. Set on `queue`.
    private var origin: ContinuousClock.Instant?
    private let queue = DispatchQueue(label: "app.livetranslate.recording", qos: .utility)
    private var files: [Track: AVAudioFile] = [:]
    /// Tracks whose file could not be opened. Retrying on every buffer
    /// would only repeat the error into the log.
    private var failed: Set<Track> = []
    private var isFinished = false

    /// A gap shorter than this is clock jitter between capture and the wall
    /// clock, not a pause, and is left alone.
    private static let gapTolerance = 0.25

    init(id: UUID, directory: URL) {
        self.id = id
        self.directory = directory
    }

    /// `pcm` is mono little-endian Int16 at the track's sample rate.
    func append(_ pcm: Data, to track: Track) {
        // Taken here, not on the queue: the queue may be running behind.
        let arrived = ContinuousClock.now
        queue.async { [self] in
            guard !isFinished, !failed.contains(track) else { return }
            if origin == nil {
                guard !Self.isSilent(pcm) else { return }
                origin = arrived
            }
            guard let origin, let file = file(for: track) else { return }
            let frames = pcm.count / MemoryLayout<Int16>.size
            guard frames > 0 else { return }
            let elapsed = origin.duration(to: arrived)
            let due = AVAudioFramePosition(
                (Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18)
                    * track.sampleRate
            )
            do {
                if Double(due - file.length) > Self.gapTolerance * track.sampleRate {
                    try writeSilence(frames: due - file.length, to: file)
                }
                try write(pcm, frames: frames, to: file)
            } catch {
                BridgeLog.audio.error(
                    "[\(track.rawValue, privacy: .public)] recording write failed: \("\(error)", privacy: .public)"
                )
            }
        }
    }

    /// Writes out what is still queued and closes every file. Synchronous,
    /// so an app that is quitting still leaves playable files: an AAC file
    /// that is never closed has no index to play from.
    func finish() {
        queue.sync {
            isFinished = true
            for file in files.values { file.close() }
            files.removeAll()
        }
    }

    /// Below -60 dBFS throughout: the digital silence an idle device
    /// delivers, with room for a dithered or noise-shaped zero.
    private static func isSilent(_ pcm: Data) -> Bool {
        pcm.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).allSatisfy { abs(Int32($0)) < 33 }
        }
    }

    private func write(_ pcm: Data, frames: Int, to file: AVAudioFile) throws {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)
        ), let channel = buffer.int16ChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            channel[0].update(from: raw.bindMemory(to: Int16.self).baseAddress!, count: frames)
        }
        try file.write(from: buffer)
    }

    /// In one-second pieces, so a long gap never needs a buffer its size.
    private func writeSilence(frames: AVAudioFramePosition, to file: AVAudioFile) throws {
        let piece = AVAudioFrameCount(file.processingFormat.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: piece),
              let channel = buffer.int16ChannelData else { return }
        channel[0].initialize(repeating: 0, count: Int(piece))
        var remaining = frames
        while remaining > 0 {
            buffer.frameLength = AVAudioFrameCount(min(remaining, AVAudioFramePosition(piece)))
            try file.write(from: buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
    }

    private func file(for track: Track) -> AVAudioFile? {
        if let file = files[track] { return file }
        let url = SessionHistory.recordingURL(for: id, track: track, in: directory)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            let file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: track.sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 32_000,
                ],
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
            files[track] = file
            return file
        } catch {
            failed.insert(track)
            BridgeLog.audio.error(
                "[\(track.rawValue, privacy: .public)] recording unavailable: \("\(error)", privacy: .public)"
            )
            return nil
        }
    }
}
