import AVFoundation
import Foundation
import Testing
@testable import LiveTranslateBridge

struct AudioRoutePolicyTests {
    @Test func disconnectedExplicitMicrophoneDoesNotBecomeDefault() {
        #expect(AudioRoutePolicy.missingExplicitInput(uid: "saved-mic", resolved: nil))
        #expect(!AudioRoutePolicy.missingExplicitInput(uid: "", resolved: nil))
    }

    @Test func duplexHardwareIsNotMistakenForLoopback() {
        let usb = AudioInputDevice(id: 1, name: "USB Audio Interface", uid: "usb", hasOutputStreams: true)
        let loopback = AudioInputDevice(id: 2, name: "BlackHole 2ch", uid: "bh", hasOutputStreams: true)
        #expect(!usb.isKnownLoopback)
        #expect(loopback.isKnownLoopback)
        #expect(!AudioRoutePolicy.feedsOwnOutput(inputUID: "usb", inputIsLoopback: false,
            localUID: "usb", remoteUID: "usb"))
        #expect(AudioRoutePolicy.feedsOwnOutput(inputUID: "bh", inputIsLoopback: true,
            localUID: "bh", remoteUID: nil))
    }
}

private func tone(rate: Double, channels: AVAudioChannelCount, frames: AVAudioFrameCount = 4800, amplitude: Float = 0.2) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0..<Int(channels) {
        for frame in 0..<Int(frames) {
            buffer.floatChannelData![channel][frame] = amplitude * sin(Float(frame) * 2 * .pi * 440 / Float(rate))
        }
    }
    return buffer
}

struct OriginalAudioConversionTests {
    @Test func monoIsAudibleInBothStereoChannels() throws {
        let converter = OriginalAudioConverter()
        let output = try #require(converter.convert(tone(rate: 48_000, channels: 1),
            to: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!))
        #expect(output.frameLength > 0)
        let left = output.floatChannelData![0], right = output.floatChannelData![1]
        #expect((0..<Int(output.frameLength)).contains { abs(left[$0]) > 0.1 })
        #expect((0..<Int(output.frameLength)).allSatisfy { abs(left[$0] - right[$0]) < 0.0001 })
    }

    @Test func sampleRateAndChannelChangesRebuildConversion() throws {
        let converter = OriginalAudioConverter()
        let destination = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        for rate in [44_100.0, 48_000.0, 32_000.0] {
            let output = try #require(converter.convert(tone(rate: rate, channels: 2), to: destination))
            #expect(output.frameLength > 0)
            #expect(output.format == destination)
            #expect((0..<Int(output.frameLength)).contains { abs(output.floatChannelData![0][$0]) > 0.05 })
        }
    }
}

@Suite(.serialized)
struct AudioPlaybackTests {
    @Test func productionGraphPlaysMonoOriginalThroughStereoLimiter() throws {
        let player = TranslationPlayer(manualRendering: true)
        try player.start(device: nil, originalVolume: 2, translationVolume: 2)
        defer { player.stop() }
        player.enqueueStagedOriginal(tone(rate: 48_000, channels: 1))
        var peak: Float = 0
        for _ in 0..<4 {
            let output = try player.renderOffline(frames: 1024)
            for frame in 0..<Int(output.frameLength) {
                peak = max(peak, abs(output.floatChannelData![0][frame]))
            }
        }
        #expect(peak > 0.05)
        #expect(peak <= 1.01)
    }

    @Test func limiterBoundsLoudMixedAudio() throws {
        let player = TranslationPlayer(manualRendering: true)
        try player.start(device: nil, originalVolume: 2, translationVolume: 2)
        defer { player.stop() }
        player.enqueueStagedOriginal(tone(rate: 48_000, channels: 1, amplitude: 0.9))
        let samples = (0..<2400).map { Int16(29_000 * sin(Double($0) * 2 * .pi * 440 / 24_000)) }
        player.enqueue(samples.withUnsafeBytes { Data($0) })
        var peak: Float = 0
        for _ in 0..<6 {
            let output = try player.renderOffline(frames: 1024)
            for frame in 0..<Int(output.frameLength) {
                peak = max(peak, abs(output.floatChannelData![0][frame]))
            }
        }
        #expect(peak > 0.1)
        #expect(peak <= 1.05)
    }

    @Test func concurrentStopCannotScheduleOnDetachedNodes() throws {
        let player = TranslationPlayer(manualRendering: true)
        try player.start(device: nil)
        let workers = DispatchGroup()
        for _ in 0..<20 {
            workers.enter()
            DispatchQueue.global().async {
                player.enqueue(Data(repeating: 0, count: 480))
                workers.leave()
            }
        }
        player.stop()
        #expect(workers.wait(timeout: .now() + 3) == .success)
        #expect(!player.isPlaying)
    }

    @Test func zeroOriginalGainReallyMutesAndStopCanRestart() throws {
        let player = TranslationPlayer(manualRendering: true)
        for _ in 0..<3 {
            try player.start(device: nil, originalVolume: 0)
            player.enqueueStagedOriginal(tone(rate: 48_000, channels: 1))
            let output = try player.renderOffline(frames: 1024)
            #expect((0..<Int(output.frameLength)).allSatisfy { abs(output.floatChannelData![0][$0]) < 0.0001 })
            player.enqueue(Data(repeating: 0, count: 4800))
            player.stop()
            #expect(!player.isPlaying)
            #expect(player.queuedTranslationSeconds == 0)
        }
    }

    @Test func skippingCompletedResponseDoesNotSkipNextResponse() throws {
        let player = TranslationPlayer(manualRendering: true)
        try player.start(device: nil)
        defer { player.stop() }
        player.enqueue(Data(repeating: 0, count: 4800))
        player.responseEnded()
        player.flush()
        player.enqueue(Data(repeating: 0, count: 4800))
        #expect(player.queuedTranslationSeconds > 0)
    }

    @Test func backlogIsBoundedAndSkipPreservesOriginal() throws {
        let player = TranslationPlayer(manualRendering: true)
        try player.start(device: nil)
        defer { player.stop() }
        for _ in 0..<20 { player.enqueue(Data(repeating: 0, count: 48_000)) }
        #expect(player.queuedTranslationSeconds <= 15)
        player.flush()
        #expect(player.queuedTranslationSeconds == 0)
        player.enqueue(Data(repeating: 0, count: 48_000))
        #expect(player.queuedTranslationSeconds == 0)
        player.enqueueStagedOriginal(tone(rate: 48_000, channels: 1))
        var audible = false
        for _ in 0..<4 {
            let output = try player.renderOffline(frames: 1024)
            audible = audible || (0..<Int(output.frameLength)).contains { abs(output.floatChannelData![0][$0]) > 0.05 }
        }
        #expect(audible)
        player.responseEnded()
        player.enqueue(Data(repeating: 0, count: 4800))
        #expect(player.queuedTranslationSeconds > 0)
    }
}

struct AudioQueueGenerationTests {
    @Test func staleSocketAudioCannotReachReplacementPlayer() throws {
        let path = TranslationPlaybackPath()
        let first = TranslationPlayer(manualRendering: true)
        try first.start(device: nil)
        path.install(first)
        let oldToken = path.token
        let second = TranslationPlayer(manualRendering: true)
        try second.start(device: nil)
        path.install(second)
        defer { path.stop() }
        path.enqueue(Data(repeating: 0, count: 4800), token: oldToken)
        #expect(second.queuedTranslationSeconds == 0)
        path.enqueue(Data(repeating: 0, count: 4800), token: path.token)
        #expect(second.queuedTranslationSeconds > 0)
    }

    @Test func invalidationDiscardsPreviousCaptureGeneration() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let delivered = DispatchSemaphore(value: 0)
        let queue = RealtimeAudioQueue(label: "test.audio.epoch", maximumAge: 3) { buffer in
            #expect(buffer.frameLength == 200)
            delivered.signal()
        } onDrop: { _ in }
        queue.perform { entered.signal(); release.wait() }
        #expect(entered.wait(timeout: .now() + 3) == .success)
        queue.enqueue(tone(rate: 48_000, channels: 1, frames: 100))
        queue.invalidate()
        queue.enqueue(tone(rate: 48_000, channels: 1, frames: 200))
        release.signal()
        #expect(delivered.wait(timeout: .now() + 3) == .success)
    }

    @Test func oldAudioExpiresBeforeProcessing() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let dropped = DispatchSemaphore(value: 0)
        let queue = RealtimeAudioQueue(label: "test.audio.expiry", maximumAge: 0.001) { _ in
            Issue.record("expired audio reached the consumer")
        } onDrop: { _ in dropped.signal() }
        queue.perform { entered.signal(); release.wait() }
        #expect(entered.wait(timeout: .now() + 3) == .success)
        queue.enqueue(tone(rate: 48_000, channels: 1, frames: 100))
        Thread.sleep(forTimeInterval: 0.02)
        release.signal()
        #expect(dropped.wait(timeout: .now() + 3) == .success)
    }
}

struct CaptureConversionTests {
    /// A stereo → mono converter without downmix keeps channel 0 only, so a
    /// source panned right reached ASR as silence.
    @Test func rightOnlyStereoReachesRecognition() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = tone(rate: 48_000, channels: 2)
        buffer.floatChannelData![0].update(repeating: 0, count: Int(buffer.frameLength))
        let pcm = try Resampler(sourceFormat: format).convert(buffer)
        let peak = pcm.withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).map { abs(Int32($0)) }.max() ?? 0 }
        #expect(peak > 1000)
    }

    /// Helpers nested in an app bundle belong to that app, not to themselves.
    @Test func helperProcessesResolveToOutermostApp() {
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/140/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        #expect(AppOwnership.outermostApp(in: helper)?.path == "/Applications/Google Chrome.app")
        #expect(AppOwnership.outermostApp(in: "/usr/libexec/avconferenced") == nil)
    }
}
