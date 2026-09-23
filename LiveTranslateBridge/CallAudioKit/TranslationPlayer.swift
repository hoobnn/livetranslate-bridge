import os
import Accelerate
import AVFoundation
import CoreAudio
import Foundation
import Synchronization

/// Two independent lanes rendered by `AVAudioSourceNode`s that pull from
/// lock-free rings, mixed and peak-limited on one output device.
///
/// Why pull rather than `AVAudioPlayerNode.scheduleBuffer`: the original lane
/// arrives in ~10 ms capture blocks, and scheduling each one from a worker
/// queue made its playback timing depend on that queue's jitter — any late
/// block was an audible gap. A pull model with a small jitter buffer gives a
/// constant latency, conceals nothing, and catches up in one step when the
/// capture clock outruns the output clock.
///
/// Gain and ducking are applied per sample on the render thread with
/// one-pole smoothing, so slider moves and ducks are click-free at any rate
/// and gains above 100 % are plain multiplications ahead of the limiter.
/// Every engine mutation stays serialized on `control`.
nonisolated public final class TranslationPlayer: @unchecked Sendable {
    /// 24 kHz mono Int16 is the service's fixed output format.
    static let translationRate = 24_000.0
    /// Translation queued beyond this is dropped for the rest of the response.
    static let translationBacklog = 15.0
    /// Original-lane jitter buffer: playback starts once this much is queued…
    static let originalTarget = 0.04
    /// …and jumps back to the target if capture runs this far ahead.
    static let originalCeiling = 0.2
    /// Ducked original level while translated speech is audible.
    static let duckLevel: Float = 0.25

    private let control = DispatchQueue(label: "app.livetranslate.player", qos: .userInitiated)
    private let controlKey = DispatchSpecificKey<UInt8>()
    private let engine = AVAudioEngine()
    private let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0, componentFlagsMask: 0
    ))
    private let manualRendering: Bool
    private var prepared = false
    private var originalNode: AVAudioSourceNode?
    private var translationNode: AVAudioSourceNode?
    private var originalRing: AudioRing?
    private var translationRing: AudioRing?
    private var originalFormat: AVAudioFormat?
    private var converter: OriginalAudioConverter?
    private var scratch: [Float] = []
    private let mix = MixState()
    private var suppressResponse = false
    private var responseActive = false
    private var reportedPlaying = false
    private var statusTimer: DispatchSourceTimer?
    private var lastSpeechStop: ContinuousClock.Instant?
    private var lastMetric: ContinuousClock.Instant = .now
    public var onPlaybackChange: (@Sendable (Bool) -> Void)?
    public var onWarning: (@Sendable (String) -> Void)?

    /// Shared between the control queue (writes targets, reads counters) and
    /// the render thread (reads targets, bumps counters).
    private final class MixState: @unchecked Sendable {
        let originalGain = AtomicGain(1)
        let translationGain = AtomicGain(1)
        let ducks = Atomic<Bool>(false)
        let underruns = Atomic<Int>(0)
        let catchUps = Atomic<Int>(0)
    }

    /// Render-thread-only smoothing state for one lane.
    private final class LaneState: @unchecked Sendable {
        var gain: Float
        var duck: Float = 1
        var primed = false
        init(gain: Float) { self.gain = gain }
    }

    public convenience init() { self.init(manualRendering: false) }

    init(manualRendering: Bool) {
        self.manualRendering = manualRendering
        control.setSpecific(key: controlKey, value: 1)
    }

    deinit { stop() }

    public func start(device: AudioOutputDevice?, originalVolume: Float = 1,
                      translationVolume: Float = 1, ducksOriginal: Bool = false) throws {
        try withControl {
            guard !prepared else { return }
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
            let outputFormat = manualRendering
                ? AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
                : engine.outputNode.inputFormat(forBus: 0)
            guard outputFormat.sampleRate > 0,
                  let original = AVAudioFormat(standardFormatWithSampleRate: outputFormat.sampleRate, channels: 2),
                  let translation = AVAudioFormat(standardFormatWithSampleRate: Self.translationRate, channels: 1)
            else { throw CallAudioError("output device reports no usable format") }

            mix.originalGain.value = Self.clamped(originalVolume)
            mix.translationGain.value = Self.clamped(translationVolume)
            mix.ducks.store(ducksOriginal, ordering: .relaxed)
            let originalRing = AudioRing(channels: 2, capacity: Int(outputFormat.sampleRate))
            let translationRing = AudioRing(
                channels: 1, capacity: Int(Self.translationRate * (Self.translationBacklog + 1))
            )
            let originalNode = Self.originalSource(
                format: original, ring: originalRing, translation: translationRing, mix: mix
            )
            let translationNode = Self.translationSource(
                format: translation, ring: translationRing, mix: mix
            )
            engine.attach(originalNode)
            engine.attach(translationNode)
            engine.attach(limiter)
            do {
                engine.connect(originalNode, to: engine.mainMixerNode, format: original)
                engine.connect(translationNode, to: engine.mainMixerNode, format: translation)
                engine.connect(engine.mainMixerNode, to: limiter, format: outputFormat)
                engine.connect(limiter, to: engine.outputNode, format: outputFormat)
                if manualRendering {
                    try engine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 4096)
                }
                try engine.start()
            } catch {
                engine.stop()
                engine.detach(originalNode)
                engine.detach(translationNode)
                engine.detach(limiter)
                if manualRendering { engine.disableManualRenderingMode() }
                throw error
            }
            self.originalNode = originalNode
            self.translationNode = translationNode
            self.originalRing = originalRing
            self.translationRing = translationRing
            originalFormat = original
            converter = OriginalAudioConverter()
            suppressResponse = false
            responseActive = false
            reportedPlaying = false
            prepared = true
            if !manualRendering { startStatusTimer() }
        }
    }

    /// Takes effect on the next render cycle; the render thread ramps to it.
    public func setVolumes(original: Float, translation: Float) {
        mix.originalGain.value = Self.clamped(original)
        mix.translationGain.value = Self.clamped(translation)
    }

    public func stop() {
        withControl {
            guard prepared else { return }
            prepared = false
            statusTimer?.cancel()
            statusTimer = nil
            engine.stop()
            if let originalNode { engine.detach(originalNode) }
            if let translationNode { engine.detach(translationNode) }
            engine.detach(limiter)
            if manualRendering { engine.disableManualRenderingMode() }
            originalNode = nil
            translationNode = nil
            originalRing = nil
            translationRing = nil
            converter = nil
            originalFormat = nil
            lastSpeechStop = nil
            if reportedPlaying { reportedPlaying = false; onPlaybackChange?(false) }
        }
    }

    /// Bound the player queue as well as the network queue. On overload stop
    /// voice output through this response's end; subtitles continue intact.
    public func enqueue(_ pcm: Data) {
        withControl {
            guard prepared, !suppressResponse, let ring = translationRing,
                  !pcm.isEmpty, pcm.count.isMultiple(of: 2) else { return }
            responseActive = true
            let frames = pcm.count / 2
            let ahead = Double(ring.availableFrames) / Self.translationRate
            guard ahead + Double(frames) / Self.translationRate <= Self.translationBacklog else {
                suppressResponse = true
                onWarning?("audio.backlog")
                BridgeLog.audio.error("translation backlog exceeded 15 s; suppressing current response")
                return
            }
            if scratch.count < frames { scratch = [Float](repeating: 0, count: frames) }
            scratch.withUnsafeMutableBufferPointer { floats in
                pcm.withUnsafeBytes { bytes in
                    let samples = bytes.bindMemory(to: Int16.self).baseAddress!
                    vDSP_vflt16(samples, 1, floats.baseAddress!, 1, vDSP_Length(frames))
                    var scale = Float(1) / 32_768
                    vDSP_vsmul(floats.baseAddress!, 1, &scale, floats.baseAddress!, 1, vDSP_Length(frames))
                }
                ring.write(frames: frames) { _ in UnsafePointer(floats.baseAddress!) }
            }
            if !reportedPlaying { reportedPlaying = true; onPlaybackChange?(true) }
            if let stopped = lastSpeechStop {
                BridgeLog.audio.notice("speech-stop to first audio received: \(String(describing: stopped.duration(to: .now)), privacy: .public); queued ahead \(ahead) s (not measured hardware latency)")
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

    /// Converts to the lane's output format and hands it to the render ring.
    func enqueueStagedOriginal(_ source: AVAudioPCMBuffer) {
        withControl {
            guard prepared, let format = originalFormat, let ring = originalRing,
                  let buffer = converter?.convert(source, to: format),
                  let channels = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            if ring.write(frames: frames, source: { UnsafePointer(channels[$0]) }) < frames {
                _ = mix.catchUps.wrappingAdd(1, ordering: .relaxed)
            }
            reportQueues()
        }
    }

    /// Interrupt translated speech without interrupting the original lane.
    public func flush() {
        withControl {
            guard prepared else { return }
            translationRing?.discard()
            suppressResponse = responseActive
            updatePlaybackState()
        }
    }

    public var isPlaying: Bool { withControl { (translationRing?.availableFrames ?? 0) > 0 } }
    public var queuedTranslationSeconds: Double {
        withControl { Double(translationRing?.availableFrames ?? 0) / Self.translationRate }
    }

    /// Uses the production graph without opening a hardware device.
    func renderOffline(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        try withControl {
            let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: frames)!
            _ = try engine.renderOffline(frames, to: buffer)
            updatePlaybackState()
            return buffer
        }
    }

    // MARK: - render

    private static func originalSource(format: AVAudioFormat, ring: AudioRing,
                                       translation: AudioRing, mix: MixState) -> AVAudioSourceNode {
        let rate = Float(format.sampleRate)
        let target = Int(originalTarget * format.sampleRate)
        let ceiling = Int(originalCeiling * format.sampleRate)
        let gainStep = smoothing(seconds: 0.015, rate: rate)
        let attack = smoothing(seconds: 0.04, rate: rate)
        let release = smoothing(seconds: 0.3, rate: rate)
        let state = LaneState(gain: mix.originalGain.value)
        return AVAudioSourceNode(format: format) { _, _, frameCount, output in
            let list = UnsafeMutableAudioBufferListPointer(output)
            let frames = Int(frameCount)
            guard list.count == ring.channelCount else { return kAudioUnitErr_FormatNotSupported }
            let channel = { (index: Int) in list[index].mData!.assumingMemoryBound(to: Float.self) }

            var available = ring.availableFrames
            if !state.primed, available >= target { state.primed = true }
            if available > ceiling {
                ring.discard(keeping: target)
                available = target
                _ = mix.catchUps.wrappingAdd(1, ordering: .relaxed)
            }
            var copied = 0
            if state.primed {
                copied = ring.read(frames: frames, into: channel)
                if copied < frames {
                    state.primed = false
                    _ = mix.underruns.wrappingAdd(1, ordering: .relaxed)
                }
            }
            for index in 0..<list.count where copied < frames {
                (channel(index) + copied).update(repeating: 0, count: frames - copied)
            }

            let goal = mix.originalGain.value
            let speaking = translation.availableFrames > 0 && mix.translationGain.value > 0
            let duckGoal: Float = mix.ducks.load(ordering: .relaxed) && speaking ? duckLevel : 1
            let duckStep = duckGoal < state.duck ? attack : release
            var gain = state.gain, duck = state.duck
            let left = channel(0), right = channel(1)
            for frame in 0..<frames {
                gain += (goal - gain) * gainStep
                duck += (duckGoal - duck) * duckStep
                let applied = gain * duck
                left[frame] *= applied
                right[frame] *= applied
            }
            state.gain = abs(goal - gain) < 1e-5 ? goal : gain
            state.duck = abs(duckGoal - duck) < 1e-5 ? duckGoal : duck
            return noErr
        }
    }

    private static func translationSource(format: AVAudioFormat, ring: AudioRing,
                                          mix: MixState) -> AVAudioSourceNode {
        let gainStep = smoothing(seconds: 0.015, rate: Float(format.sampleRate))
        let state = LaneState(gain: mix.translationGain.value)
        return AVAudioSourceNode(format: format) { isSilence, _, frameCount, output in
            let list = UnsafeMutableAudioBufferListPointer(output)
            let frames = Int(frameCount)
            guard let samples = list.first?.mData?.assumingMemoryBound(to: Float.self) else {
                return kAudioUnitErr_FormatNotSupported
            }
            let copied = ring.read(frames: frames) { _ in samples }
            if copied < frames { (samples + copied).update(repeating: 0, count: frames - copied) }
            let goal = mix.translationGain.value
            if copied == 0, goal == state.gain {
                isSilence.pointee = true
                return noErr
            }
            var gain = state.gain
            for frame in 0..<frames {
                gain += (goal - gain) * gainStep
                samples[frame] *= gain
            }
            state.gain = abs(goal - gain) < 1e-5 ? goal : gain
            return noErr
        }
    }

    /// Per-sample coefficient of a one-pole smoother with time constant `seconds`.
    private static func smoothing(seconds: Float, rate: Float) -> Float {
        1 - exp(-1 / (seconds * rate))
    }

    // MARK: - status

    private func startStatusTimer() {
        let timer = DispatchSource.makeTimerSource(queue: control)
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20),
                       leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.updatePlaybackState() }
        timer.resume()
        statusTimer = timer
    }

    /// Called on `control`. Reports drain transitions the render thread cannot.
    private func updatePlaybackState() {
        guard prepared else { return }
        let playing = (translationRing?.availableFrames ?? 0) > 0
        if playing != reportedPlaying {
            reportedPlaying = playing
            onPlaybackChange?(playing)
        }
        reportQueues()
    }

    private func reportQueues() {
        guard lastMetric.duration(to: .now) >= .seconds(2) else { return }
        lastMetric = .now
        let rate = originalFormat?.sampleRate ?? 48_000
        let original = Double(originalRing?.availableFrames ?? 0) / rate
        let translation = Double(translationRing?.availableFrames ?? 0) / Self.translationRate
        let underruns = mix.underruns.exchange(0, ordering: .relaxed)
        let catchUps = mix.catchUps.exchange(0, ordering: .relaxed)
        BridgeLog.audio.info("playback queue: original \(original) s, translation \(translation) s; original underruns \(underruns), catch-ups \(catchUps)")
    }

    /// The last reference can be released by a timer on this queue.
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
