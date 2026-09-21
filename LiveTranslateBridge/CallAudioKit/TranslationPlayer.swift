import os
import AVFoundation
import CoreAudio
import Foundation

/// Plays a route's captured original and synthesised translation into one
/// chosen output device with independent gains.
nonisolated public final class TranslationPlayer: @unchecked Sendable {
    private static let serviceSampleRate: Double = 24_000

    private let engine = AVAudioEngine()
    private let translationPlayer = AVAudioPlayerNode()
    private let originalPlayer = AVAudioPlayerNode()
    private let lock = NSLock()
    private var isPrepared = false
    private var translationFormat: AVAudioFormat?
    private var originalFormat: AVAudioFormat?
    private var originalPlaybackFormat: AVAudioFormat?
    private var originalConverter: AVAudioConverter?

    private let originalQueue: RealtimeAudioQueue
    private let originalCallback: OriginalCallback

    private final class OriginalCallback: @unchecked Sendable {
        weak var owner: TranslationPlayer?
    }

    private var inFlight = 0
    public var onPlaybackChange: (@Sendable (Bool) -> Void)?

    public init() {
        let callback = OriginalCallback()
        originalCallback = callback
        originalQueue = RealtimeAudioQueue(
            label: "app.livetranslate.playback.original"
        ) { [weak callback] buffer in
            callback?.owner?.scheduleOriginal(buffer)
        } onDrop: { count in
            BridgeLog.audio.error(
                "original playback queue dropped \(count, privacy: .public) buffers"
            )
        }
        callback.owner = self
    }
    deinit { stop() }

    /// Opens the route against `device`, or the system default when nil.
    public func start(
        device: AudioOutputDevice?,
        originalVolume: Float = 1,
        translationVolume: Float = 1
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isPrepared else { return }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.serviceSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw CallAudioError("cannot build 24 kHz mono playback format")
        }
        translationFormat = format

        if let device {
            var status = OSStatus(kAudioUnitErr_InvalidElement)
            engine.outputNode.withAudioUnit { unit in
                guard let unit else { return }
                var deviceID = device.id
                status = AudioUnitSetProperty(
                    unit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &deviceID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
            }
            guard status == noErr else {
                throw CallAudioError.status(
                    "selecting output device \(device.name)", status
                )
            }
            BridgeLog.audio.notice(
                "audio route bound to \(device.name, privacy: .public)"
            )
        }

        engine.attach(translationPlayer)
        engine.attach(originalPlayer)
        originalPlayer.volume = Self.clamped(originalVolume)
        translationPlayer.volume = Self.clamped(translationVolume)

        do {
            try engine.connectNode(
                translationPlayer, to: engine.mainMixerNode, format: format
            )
            // Connect both lanes before starting the engine. Reconnecting a
            // player after the engine is live can leave AVAudioPlayerNode in
            // a disconnected state on macOS even when the graph call itself
            // succeeds. A nil format adopts the output route's native format;
            // captured audio is converted to that format before scheduling.
            try engine.connectNode(
                originalPlayer, to: engine.mainMixerNode, format: nil
            )
            try engine.start()
            originalPlaybackFormat = originalPlayer.outputFormat(forBus: 0)
            if let originalPlaybackFormat {
                BridgeLog.audio.notice(
                    "original playback format: \(originalPlaybackFormat.sampleRate, privacy: .public) Hz \(originalPlaybackFormat.channelCount, privacy: .public) ch interleaved=\(originalPlaybackFormat.isInterleaved, privacy: .public)"
                )
            }
            try translationPlayer.playAudio()
            try originalPlayer.playAudio()
        } catch {
            engine.stop()
            engine.detach(translationPlayer)
            engine.detach(originalPlayer)
            throw CallAudioError("cannot start playback engine: \(error)")
        }
        isPrepared = true
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isPrepared else { return }
        isPrepared = false
        translationPlayer.stop()
        originalPlayer.stop()
        engine.stop()
        engine.detach(translationPlayer)
        engine.detach(originalPlayer)
        translationFormat = nil
        originalFormat = nil
        originalPlaybackFormat = nil
        originalConverter = nil
        let wasPlaying = inFlight > 0
        inFlight = 0
        if wasPlaying { onPlaybackChange?(false) }
    }

    /// Queues one model audio chunk: little-endian Int16 at 24 kHz.
    public func enqueue(_ pcm: Data) {
        lock.lock()
        guard isPrepared, let format = translationFormat else {
            lock.unlock()
            return
        }
        let frames = pcm.count / MemoryLayout<Int16>.size
        guard frames > 0, let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)
        ) else {
            lock.unlock()
            return
        }

        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            buffer.int16ChannelData![0].update(
                from: base.assumingMemoryBound(to: Int16.self), count: frames
            )
        }

        let wasIdle = inFlight == 0
        inFlight += 1
        lock.unlock()
        if wasIdle { onPlaybackChange?(true) }

        translationPlayer.scheduleBuffer(
            buffer, completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.inFlight = max(0, self.inFlight - 1)
            let nowIdle = self.inFlight == 0
            self.lock.unlock()
            if nowIdle { self.onPlaybackChange?(false) }
        }
    }

    @available(macOS 14.2, *)
    public func enqueueOriginal(_ buffer: DownlinkTap.Buffer) {
        originalQueue.enqueue(buffer)
    }

    public func enqueueOriginal(_ buffer: AVAudioPCMBuffer) {
        originalQueue.enqueue(buffer)
    }

    private func scheduleOriginal(_ staged: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard isPrepared, let playbackFormat = originalPlaybackFormat,
              let buffer = convertOriginal(staged, to: playbackFormat) else { return }

        if originalFormat == nil {
            originalFormat = staged.format
            BridgeLog.audio.notice(
                "original playback lane ready: \(staged.format.sampleRate, privacy: .public) Hz \(staged.format.channelCount, privacy: .public) ch"
            )
        }
        guard originalFormat == staged.format else {
            BridgeLog.audio.error("original playback format changed during the route")
            return
        }
        originalPlayer.scheduleBuffer(buffer)
    }

    private func convertOriginal(
        _ source: AVAudioPCMBuffer,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard source.format.commonFormat == .pcmFormatFloat32,
              format.commonFormat == .pcmFormatFloat32,
              source.format.channelCount == format.channelCount else { return nil }

        if originalFormat != source.format || originalConverter == nil {
            originalConverter = AVAudioConverter(from: source.format, to: format)
        }
        guard let converter = originalConverter else { return nil }

        let ratio = format.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(
            ceil(Double(source.frameLength) * ratio) + 8
        )
        guard let output = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: capacity
        ) else { return nil }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) {
            _, inputStatus in
            guard !supplied else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return source
        }
        if status == .error {
            BridgeLog.audio.error(
                "cannot convert original audio: \("\(conversionError?.localizedDescription ?? "unknown error")", privacy: .public)"
            )
            return nil
        }
        return output.frameLength > 0 ? output : nil
    }

    public func flush() {
        lock.lock()
        guard isPrepared else { lock.unlock(); return }
        let wasPlaying = inFlight > 0
        inFlight = 0
        translationPlayer.stop()
        originalPlayer.stop()
        try? translationPlayer.playAudio()
        if originalFormat != nil { try? originalPlayer.playAudio() }
        lock.unlock()
        if wasPlaying { onPlaybackChange?(false) }
    }

    public var isPlaying: Bool {
        lock.lock(); defer { lock.unlock() }
        return inFlight > 0
    }

    private static func clamped(_ volume: Float) -> Float {
        min(max(volume, 0), 2)
    }
}
