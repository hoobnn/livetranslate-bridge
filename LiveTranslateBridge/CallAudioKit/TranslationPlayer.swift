import os
import AVFoundation
import CoreAudio
import Foundation

/// Two independent lanes, with every engine mutation serialized off the audio
/// callback. Completion handlers only enqueue work: stop() may invoke them inline.
nonisolated public final class TranslationPlayer: @unchecked Sendable {
    private let control = DispatchQueue(label: "app.livetranslate.player", qos: .userInitiated)
    private let controlKey = DispatchSpecificKey<UInt8>()
    private let engine = AVAudioEngine()
    private let translationPlayer = AVAudioPlayerNode()
    private let originalPlayer = AVAudioPlayerNode()
    private let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0, componentFlagsMask: 0
    ))
    private let manualRendering: Bool
    private var prepared = false
    private var translationFormat: AVAudioFormat?
    private var originalPlaybackFormat: AVAudioFormat?
    private var converter: OriginalAudioConverter?
    private var originalSeconds = 0.0
    private var translationSeconds = 0.0
    private var originalGeneration = 0
    private var translationGeneration = 0
    private var suppressResponse = false
    private var responseActive = false
    private var volumeGeneration = 0
    private var originalGain: Float = 1
    private var translationGain: Float = 1
    private var ducksOriginal = false
    private var lastSpeechStop: ContinuousClock.Instant?
    private var lastMetric: ContinuousClock.Instant = .now
    public var onPlaybackChange: (@Sendable (Bool) -> Void)?
    public var onWarning: (@Sendable (String) -> Void)?

    private final class Callback: @unchecked Sendable { weak var owner: TranslationPlayer? }
    private let callback: Callback
    private let originalQueue: RealtimeAudioQueue

    public convenience init() { self.init(manualRendering: false) }

    init(manualRendering: Bool) {
        self.manualRendering = manualRendering
        let callback = Callback()
        self.callback = callback
        originalQueue = RealtimeAudioQueue(label: "app.livetranslate.original", maximumAge: 0.25) {
            [weak callback] buffer in
            callback?.owner?.scheduleOriginal(buffer)
        } onDrop: { count in
            BridgeLog.audio.notice("original queue discarded \(count) stale/full buffers")
        }
        callback.owner = self
        control.setSpecific(key: controlKey, value: 1)
    }

    deinit { stop() }

    public func start(device: AudioOutputDevice?, originalVolume: Float = 1,
                      translationVolume: Float = 1, ducksOriginal: Bool = false) throws {
        try withControl {
            guard !prepared else { return }
            guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                sampleRate: 24_000, channels: 1, interleaved: true) else {
                throw CallAudioError("cannot create translation format")
            }
            if let device {
                var status = OSStatus(kAudioUnitErr_InvalidElement)
                engine.outputNode.withAudioUnit { unit in
                    guard let unit else { return }
                    var id = device.id
                    status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                        kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
                }
                guard status == noErr else { throw CallAudioError.status("select output", status) }
            }
            engine.attach(translationPlayer)
            engine.attach(originalPlayer)
            engine.attach(limiter)
            do {
                try engine.connectNode(translationPlayer, to: engine.mainMixerNode, format: format)
                try engine.connectNode(originalPlayer, to: engine.mainMixerNode, format: nil)
                let outputFormat = manualRendering
                    ? AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
                    : engine.outputNode.inputFormat(forBus: 0)
                try engine.connectNode(engine.mainMixerNode, to: limiter, format: outputFormat)
                try engine.connectNode(limiter, to: engine.outputNode, format: outputFormat)
                self.ducksOriginal = ducksOriginal
                originalGain = Self.clamped(originalVolume)
                translationGain = Self.clamped(translationVolume)
                originalPlayer.volume = originalGain
                translationPlayer.volume = translationGain
                if manualRendering {
                    try engine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 4096)
                }
                try engine.start()
                try originalPlayer.playAudio()
                try translationPlayer.playAudio()
                originalPlaybackFormat = originalPlayer.outputFormat(forBus: 0)
                translationFormat = format
                converter = OriginalAudioConverter()
                suppressResponse = false
                responseActive = false
                prepared = true
            } catch {
                engine.stop()
                engine.detach(translationPlayer)
                engine.detach(originalPlayer)
                engine.detach(limiter)
                if manualRendering { engine.disableManualRenderingMode() }
                throw error
            }
        }
    }

    /// A short ramp avoids hard gain steps. New changes invalidate older ramps.
    public func setVolumes(original: Float, translation: Float) {
        control.async { [weak self] in
            guard let self, self.prepared else { return }
            self.originalGain = Self.clamped(original)
            self.translationGain = Self.clamped(translation)
            self.rampVolumes()
        }
    }

    private func rampVolumes() {
        guard prepared else { return }
        volumeGeneration &+= 1
        let generation = volumeGeneration
        let a = originalPlayer.volume, b = translationPlayer.volume
        let original = originalGain * (ducksOriginal && translationSeconds > 0 && translationGain > 0 ? 0.25 : 1)
        let translation = translationGain
        for step in 1...5 {
            control.asyncAfter(deadline: .now() + .milliseconds(step * 5)) { [weak self] in
                guard let self, self.prepared, self.volumeGeneration == generation else { return }
                let fraction = Float(step) / 5
                self.originalPlayer.volume = a + (original - a) * fraction
                self.translationPlayer.volume = b + (translation - b) * fraction
            }
        }
    }

    public func stop() {
        originalQueue.invalidate()
        withControl {
            guard prepared else { return }
            prepared = false
            volumeGeneration &+= 1
            resetTranslation()
            resetOriginal()
            engine.stop()
            engine.detach(translationPlayer)
            engine.detach(originalPlayer)
            engine.detach(limiter)
            if manualRendering { engine.disableManualRenderingMode() }
            converter = nil
            originalPlaybackFormat = nil
            translationFormat = nil
            lastSpeechStop = nil
        }
    }

    /// Bound the player queue as well as the network queue. On overload stop
    /// voice output through this response's end; subtitles continue intact.
    public func enqueue(_ pcm: Data) {
        withControl {
            guard prepared, !suppressResponse, let format = translationFormat,
                  !pcm.isEmpty, pcm.count.isMultiple(of: 2) else { return }
            responseActive = true
            let frames = pcm.count / 2
            let seconds = Double(frames) / 24_000
            guard translationSeconds + seconds <= 15 else {
                suppressResponse = true
                onWarning?("audio.backlog")
                BridgeLog.audio.error("translation backlog exceeded 15 s; suppressing current response")
                return
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frames)) else { return }
            buffer.frameLength = AVAudioFrameCount(frames)
            pcm.withUnsafeBytes { bytes in
                buffer.int16ChannelData![0].update(
                    from: bytes.bindMemory(to: Int16.self).baseAddress!, count: frames)
            }
            let idle = translationSeconds == 0
            let ahead = translationSeconds
            translationSeconds += seconds
            let generation = translationGeneration
            let received = ContinuousClock.now
            translationPlayer.scheduleBuffer(buffer, completionCallbackType: manualRendering ? .dataRendered : .dataPlayedBack) {
                [weak self] _ in
                self?.control.async { [weak self] in
                    guard let self, self.translationGeneration == generation else { return }
                    self.translationSeconds = max(0, self.translationSeconds - seconds)
                    if self.translationSeconds < 0.0001 {
                        self.translationSeconds = 0
                        self.onPlaybackChange?(false)
                        self.rampVolumes()
                    }
                }
            }
            if idle { onPlaybackChange?(true); rampVolumes() }
            if let stopped = lastSpeechStop {
                BridgeLog.audio.notice("speech-stop to first audio received: \(String(describing: stopped.duration(to: received)), privacy: .public); queued ahead \(ahead) s (not measured hardware latency)")
                lastSpeechStop = nil
            }
            reportQueues()
        }
    }

    public func responseEnded() {
        withControl { suppressResponse = false; responseActive = false }
    }

    public func speechStopped() {
        withControl { lastSpeechStop = .now }
    }

    @available(macOS 14.2, *)
    public func enqueueOriginal(_ buffer: DownlinkTap.Buffer) { originalQueue.enqueue(buffer) }
    public func enqueueOriginal(_ buffer: AVAudioPCMBuffer) { originalQueue.enqueue(buffer) }

    private func scheduleOriginal(_ source: AVAudioPCMBuffer) {
        withControl {
            guard prepared, let format = originalPlaybackFormat,
                  let buffer = converter?.convert(source, to: format) else { return }
            let seconds = Double(buffer.frameLength) / format.sampleRate
            if originalSeconds + seconds > 0.25 {
                resetOriginal()
                try? originalPlayer.playAudio()
                BridgeLog.audio.notice("original playback caught up to live audio")
            }
            originalSeconds += seconds
            let generation = originalGeneration
            originalPlayer.scheduleBuffer(buffer, completionCallbackType: manualRendering ? .dataRendered : .dataPlayedBack) {
                [weak self] _ in
                self?.control.async { [weak self] in
                    guard let self, self.originalGeneration == generation else { return }
                    self.originalSeconds = max(0, self.originalSeconds - seconds)
                }
            }
            reportQueues()
        }
    }

    /// Interrupt translated speech without interrupting the original lane.
    public func flush() {
        withControl {
            guard prepared else { return }
            resetTranslation()
            suppressResponse = responseActive
            try? translationPlayer.playAudio()
        }
    }

    public var isPlaying: Bool { withControl { translationSeconds > 0 } }
    public var queuedTranslationSeconds: Double { withControl { translationSeconds } }

    private func resetOriginal() {
        originalGeneration &+= 1
        originalSeconds = 0
        originalPlayer.stop()
    }

    private func resetTranslation() {
        translationGeneration &+= 1
        let speaking = translationSeconds > 0
        translationSeconds = 0
        translationPlayer.stop()
        if speaking { onPlaybackChange?(false); rampVolumes() }
    }

    /// Uses the production graph without opening a hardware device.
    func renderOffline(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        try withControl {
            let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: frames)!
            _ = try engine.renderOffline(frames, to: buffer)
            return buffer
        }
    }

    func enqueueStagedOriginal(_ buffer: AVAudioPCMBuffer) { scheduleOriginal(buffer) }

    private func reportQueues() {
        guard lastMetric.duration(to: .now) >= .seconds(2) else { return }
        lastMetric = .now
        BridgeLog.audio.info("playback queue: original \(self.originalSeconds) s, translation \(self.translationSeconds) s")
    }

    /// The last reference can be released by a completion/ramp on this queue.
    /// Avoid dispatch_sync onto ourselves when deinit then calls stop().
    private func withControl<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: controlKey) != nil { return try work() }
        return try control.sync(execute: work)
    }

    private static func clamped(_ gain: Float) -> Float {
        gain.isFinite ? min(max(gain, 0), 2) : 0
    }
}

/// Owns format-dependent conversion. Rebuilt on source/output changes, including
/// mono → stereo and stereo → mono. Output ownership passes to the player.
nonisolated final class OriginalAudioConverter {
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var destinationFormat: AVAudioFormat?

    func convert(_ source: AVAudioPCMBuffer, to destination: AVAudioFormat) -> AVAudioPCMBuffer? {
        if sourceFormat != source.format || destinationFormat != destination {
            converter = AVAudioConverter(from: source.format, to: destination)
            sourceFormat = source.format
            destinationFormat = destination
            if source.format.channelCount == 1, destination.channelCount > 1 {
                converter?.channelMap = Array(repeating: NSNumber(value: 0), count: Int(destination.channelCount))
            } else if destination.channelCount == 1 {
                converter?.downmix = true
            }
        }
        guard let converter else { return nil }
        let frames = AVAudioFrameCount(ceil(Double(source.frameLength) * destination.sampleRate / source.format.sampleRate) + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: destination, frameCapacity: frames) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            guard !supplied else { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return source
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}
