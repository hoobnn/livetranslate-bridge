import os
import AVFoundation
import CoreAudio
import Foundation

/// Plays the service's synthesised translation into a chosen output device.
///
/// The service returns 24 kHz mono Int16 in `response.audio.delta` chunks that
/// arrive faster than real time — a whole sentence can land in a few hundred
/// milliseconds. So this is a queue, not a pipe: chunks are scheduled on an
/// `AVAudioPlayerNode`, which plays them back gaplessly at the right rate.
///
/// The output device matters. Routed at the speakers it is a talkback aid;
/// routed at a loopback device that the user has also set as the system default
/// input, it becomes our side of the call — Continuity relay reads the uplink
/// from that default input, so whatever is played there is what the far end
/// hears. See `AudioOutputDevice`.
nonisolated public final class TranslationPlayer: @unchecked Sendable {
    /// The format of `response.audio.delta`, fixed by the model.
    private static let serviceSampleRate: Double = 24_000

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private var isPrepared = false
    private var sourceFormat: AVAudioFormat?

    /// Chunks scheduled but not yet finished playing. Used to tell the UI that
    /// translated speech is currently on the wire, which is what makes the
    /// "speak my translation" mode legible rather than mysterious.
    private var inFlight = 0
    public var onPlaybackChange: (@Sendable (Bool) -> Void)?

    public init() {}
    deinit { stop() }

    /// Opens the engine against `device`, or the system default when nil.
    ///
    /// Selecting the device has to happen on the engine's output *audio unit*
    /// before the engine starts; `AVAudioEngine` has no device property of its
    /// own on macOS.
    public func start(device: AudioOutputDevice?) throws {
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
        sourceFormat = format

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
                "translation playback routed to \(device.name, privacy: .public)"
            )
        }

        engine.attach(player)
        // Connected through the mixer at the service's format so the engine
        // handles the 24 kHz → device-rate conversion; the player node is
        // scheduled with buffers in that same format.
        do {
            try engine.connectNode(player, to: engine.mainMixerNode, format: format)
            try engine.start()
            try player.playAudio()
        } catch {
            engine.stop()
            engine.detach(player)
            throw CallAudioError("cannot start playback engine: \(error)")
        }
        isPrepared = true
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isPrepared else { return }
        isPrepared = false
        player.stop()
        engine.stop()
        engine.detach(player)
        sourceFormat = nil
        let wasPlaying = inFlight > 0
        inFlight = 0
        if wasPlaying { onPlaybackChange?(false) }
    }

    /// Queues one `response.audio.delta` payload: little-endian Int16 at 24 kHz.
    public func enqueue(_ pcm: Data) {
        lock.lock()
        guard isPrepared, let format = sourceFormat else { lock.unlock(); return }
        let frames = pcm.count / MemoryLayout<Int16>.size
        guard frames > 0, let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)
        ) else { lock.unlock(); return }

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

        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) {
            [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.inFlight = max(0, self.inFlight - 1)
            let nowIdle = self.inFlight == 0
            self.lock.unlock()
            if nowIdle { self.onPlaybackChange?(false) }
        }
    }

    /// Drops anything still queued — used when a session stops mid-sentence, so
    /// the tail of a translation does not keep playing into a finished call.
    public func flush() {
        lock.lock()
        guard isPrepared else { lock.unlock(); return }
        let wasPlaying = inFlight > 0
        inFlight = 0
        lock.unlock()
        player.stop()
        // A failure here only means the next chunk restarts the node; the
        // flush itself has already done its job.
        try? player.playAudio()
        if wasPlaying { onPlaybackChange?(false) }
    }

    public var isPlaying: Bool {
        lock.lock(); defer { lock.unlock() }
        return inFlight > 0
    }
}
