import AVFoundation
import CoreAudio
import Foundation
import Synchronization
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
        let usbOut = AudioOutputDevice(id: 1, name: "USB Audio Interface", uid: "usb", hasInputStreams: true)
        let bhOut = AudioOutputDevice(id: 2, name: "BlackHole 2ch", uid: "bh", hasInputStreams: true)
        #expect(!AudioRoutePolicy.feedsOwnOutput(input: usb, outputs: [usbOut, usbOut]))
        #expect(AudioRoutePolicy.feedsOwnOutput(input: loopback, outputs: [bhOut, nil]))
        #expect(!AudioRoutePolicy.feedsOwnOutput(input: loopback, outputs: [nil, usbOut]))
    }

    /// A user-named aggregate hides the loopback inside it; so does a
    /// multi-output device on the other side. Either way the app would read
    /// back its own translation.
    @Test func aggregatesAreCheckedThroughTheirMembers() {
        let blackHole = AudioDeviceMember(uid: "bh", name: "BlackHole 2ch")
        let mic = AudioDeviceMember(uid: "mic", name: "MacBook Pro Microphone")
        let aggregate = AudioInputDevice(id: 3, name: "Studio", uid: "agg", hasOutputStreams: false,
                                         members: [mic, blackHole])
        #expect(aggregate.isKnownLoopback)
        #expect(aggregate.loopbackUIDs == ["bh"])

        let bhOut = AudioOutputDevice(id: 2, name: "BlackHole 2ch", uid: "bh", hasInputStreams: true)
        #expect(AudioRoutePolicy.feedsOwnOutput(input: aggregate, outputs: [bhOut]))

        let speakers = AudioDeviceMember(uid: "spk", name: "MacBook Pro Speakers")
        let multiOutput = AudioOutputDevice(id: 4, name: "Both", uid: "multi", hasInputStreams: false,
                                            members: [speakers, blackHole])
        let blackHoleIn = AudioInputDevice(id: 2, name: "BlackHole 2ch", uid: "bh", hasOutputStreams: true)
        #expect(AudioRoutePolicy.feedsOwnOutput(input: blackHoleIn, outputs: [nil, multiOutput]))

        let plainMics = AudioInputDevice(id: 5, name: "Two Mics", uid: "mics", hasOutputStreams: false,
                                         members: [mic, AudioDeviceMember(uid: "usb", name: "USB Mic")])
        #expect(!AudioRoutePolicy.feedsOwnOutput(input: plainMics, outputs: [bhOut, multiOutput]))
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
    /// A backlog speeds translated speech up rather than letting the lag
    /// grow, and normal speed returns once it drains.
    @Test func backlogSpeedsPlaybackUpUntilItDrains() throws {
        let player = TranslationPlayer(manualRendering: true)
        try player.start(device: nil)
        defer { player.stop() }
        #expect(player.playbackRateForTesting == 1)
        // 4 s of 24 kHz Int16.
        player.enqueue(Data(repeating: 0, count: 192_000))
        _ = try player.renderOffline(frames: 1024)
        #expect(player.playbackRateForTesting == TranslationPlayer.catchUpRate)
        player.enqueue(Data(repeating: 0, count: 144_000))
        _ = try player.renderOffline(frames: 1024)
        #expect(player.playbackRateForTesting == TranslationPlayer.rushRate)
        player.flush()
        _ = try player.renderOffline(frames: 1024)
        #expect(player.playbackRateForTesting == 1)
    }

    /// Sped-up speech still comes out: a format the time-pitch unit refused
    /// would render silence rather than throw.
    @Test func spedUpTranslationIsStillAudible() throws {
        let player = TranslationPlayer(manualRendering: true)
        try player.start(device: nil)
        defer { player.stop() }
        var samples = (0..<96_000).map { Int16(12_000 * sin(Double($0) * 2 * .pi * 440 / 24_000)) }
        player.enqueue(Data(bytes: &samples, count: samples.count * 2))
        var audible = false
        for _ in 0..<16 {
            let output = try player.renderOffline(frames: 1024)
            audible = audible || (0..<Int(output.frameLength)).contains { abs(output.floatChannelData![0][$0]) > 0.05 }
        }
        #expect(player.playbackRateForTesting == TranslationPlayer.catchUpRate)
        #expect(audible)
    }

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

    /// Four-channel blocks through a fresh queue; returns each block's
    /// peak over its second half, past the gain ramp from the block before.
    private func foldedPeaks(_ blocks: [AVAudioPCMBuffer]) throws -> [Float] {
        let delivered = DispatchSemaphore(value: 0)
        let peaks = Mutex<[Float]>([])
        let queue = RealtimeAudioQueue(label: "test.audio.fold") { mono in
            #expect(mono.format.channelCount == 1)
            let tail = (Int(mono.frameLength) / 2)..<Int(mono.frameLength)
            peaks.withLock { $0.append(tail.map { abs(mono.floatChannelData![0][$0]) }.max() ?? 0) }
            delivered.signal()
        } onDrop: { _ in Issue.record("multichannel capture was dropped") }
        for block in blocks {
            queue.enqueue(block)
            #expect(delivered.wait(timeout: .now() + 3) == .success)
        }
        return peaks.withLock { $0 }
    }

    /// A 480-frame four-channel block; `fill(channel, frame)` gives each sample.
    private func fourChannels(interleaved: Bool, fill: (Int, Int) -> Float) throws -> AVAudioPCMBuffer {
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                   interleaved: interleaved, channelLayout: layout)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        for channel in 0..<4 {
            for frame in 0..<480 {
                if interleaved { buffer.floatChannelData![0][frame * 4 + channel] = fill(channel, frame) }
                else { buffer.floatChannelData![channel][frame] = fill(channel, frame) }
            }
        }
        return buffer
    }

    private func sine(_ frame: Int) -> Float { 0.4 * sin(Float(frame) * 2 * .pi * 440 / 48_000) }

    /// More than two channels cannot be described without a layout, and with a
    /// discrete layout the converter renders silence. The queue folds them to
    /// mono, so a microphone on any input of an interface reaches ASR at level,
    /// and the same signal on two inputs is averaged rather than doubled.
    @Test(arguments: [false, true])
    func multichannelCaptureIsFoldedToMono(interleaved: Bool) throws {
        // Only input 3 carries signal.
        let single = try fourChannels(interleaved: interleaved) { $0 == 2 ? sine($1) : 0 }
        #expect(abs(try foldedPeaks([single])[0] - 0.4) < 0.01)
        // Inputs 1 and 2 carry the same programme: averaged, not summed to 0.8.
        let doubled = try fourChannels(interleaved: interleaved) { $0 < 2 ? sine($1) : 0 }
        let peaks = try foldedPeaks([doubled, doubled])
        #expect(abs(peaks[1] - 0.4) < 0.01)
    }

    /// An idle input whose noise sits just under speech level must not flip
    /// in and out of the average and put a tremolo on the microphone.
    @Test func idleInputNoiseDoesNotPumpTheFold() throws {
        var generator = SystemRandomNumberGenerator()
        // −58 dBFS of noise on input 2, the voice on input 1.
        let blocks = try (0..<40).map { _ in
            try fourChannels(interleaved: false) { channel, frame in
                channel == 0 ? sine(frame)
                    : channel == 1 ? Float.random(in: -0.00126...0.00126, using: &generator) : 0
            }
        }
        let peaks = try foldedPeaks(blocks)
        #expect(peaks.allSatisfy { abs($0 - 0.4) < 0.01 })
    }

    /// An aggregate's input arrives as one buffer per member stream, each
    /// interleaving its own channels. Every channel of every stream has to
    /// reach the fold, not only the first stream's.
    @Test func multiStreamCaptureReachesEveryChannel() throws {
        let frames = 256
        let first = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        let second = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        defer { first.deallocate(); second.deallocate() }
        first.update(repeating: 0, count: frames * 2)
        second.update(repeating: 0, count: frames * 2)
        // Signal only on the second stream's first channel: overall channel 3.
        for frame in 0..<frames { second[frame * 2] = 0.4 * sin(Float(frame) * 2 * .pi * 440 / 48_000) }
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        list[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: first)
        list[1] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: second)
        let captured = try #require(CapturedAudio(buffers: list.unsafePointer, sampleRate: 48_000))
        #expect(captured.channelCount == 4)
        #expect(captured.frameCount == frames)

        let delivered = DispatchSemaphore(value: 0)
        let peak = Mutex<Float>(0)
        let queue = RealtimeAudioQueue(label: "test.audio.streams") { mono in
            peak.withLock { value in
                for frame in 0..<Int(mono.frameLength) { value = max(value, abs(mono.floatChannelData![0][frame])) }
            }
            delivered.signal()
        } onDrop: { _ in Issue.record("multi-stream capture was dropped") }
        queue.enqueue(captured)
        #expect(delivered.wait(timeout: .now() + 3) == .success)
        #expect(abs(peak.withLock { $0 } - 0.4) < 0.01)
    }

    /// The whole in-app input path after capture: 48 kHz stereo in IO-sized
    /// blocks becomes 40 ms chunks of 16 kHz mono Int16 at the same pitch
    /// and duration, in order.
    @Test func capturePathProducesPacedSixteenKilohertzChunks() throws {
        let client = TranslationClient(config: .init(apiKey: "test", workspaceID: "test", targetLanguage: "en"))
        client.simulateDropForTesting()
        let path = SubtitleModel.AudioPath(direction: .local)
        path.install(client: client)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        for block in 0..<94 {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
            buffer.frameLength = 512
            for channel in 0..<2 {
                for frame in 0..<512 {
                    buffer.floatChannelData![channel][frame] = 0.3 * sin(Float(block * 512 + frame) * 2 * .pi * 440 / 48_000)
                }
            }
            path.enqueueForTesting(buffer)
            // Keep the ring from filling: the IO thread publishes at this pace.
            if block % 8 == 7 { path.drainForTesting() }
        }
        path.drainForTesting()
        let chunks = client.bufferedChunksForTesting
        #expect(chunks.allSatisfy { $0.count == 1_280 })
        let samples = chunks.flatMap { chunk in chunk.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) } }
        // 94 × 512 frames at 48 kHz is 1.003 s; whole 40 ms chunks of it.
        #expect((15_360...16_040).contains(samples.count))
        var crossings = 0
        for index in 1..<samples.count where (samples[index - 1] < 0) != (samples[index] < 0) { crossings += 1 }
        let hertz = Double(crossings) / 2 / (Double(samples.count) / 16_000)
        #expect(abs(hertz - 440) < 5)
        let loudest = samples.map { abs(Int32($0)) }.max() ?? 0
        #expect(abs(Double(loudest) / 32_768 - 0.3) < 0.02)
    }

    /// Recording does not depend on a socket: the converted audio of a side
    /// lands in that side's file, and only that side's, and plays back at
    /// the length it was captured.
    @Test func recordingKeepsEachCapturedSideInItsOwnFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = SessionRecorder(id: UUID(), directory: directory)
        let path = SubtitleModel.AudioPath(direction: .remote)
        path.record(into: recorder)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        for block in 0..<94 {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
            buffer.frameLength = 512
            for channel in 0..<2 {
                for frame in 0..<512 {
                    buffer.floatChannelData![channel][frame] = 0.3 * sin(Float(block * 512 + frame) * 2 * .pi * 440 / 48_000)
                }
            }
            path.enqueueForTesting(buffer)
            if block % 8 == 7 { path.drainForTesting() }
        }
        path.drainForTesting()
        recorder.finish()
        let remote = SessionHistory.recordingURL(for: recorder.id, track: .remote, in: directory)
        let local = SessionHistory.recordingURL(for: recorder.id, track: .local, in: directory)
        #expect(!FileManager.default.fileExists(atPath: local.path(percentEncoded: false)))
        let file = try AVAudioFile(forReading: remote)
        #expect(file.fileFormat.sampleRate == 16_000)
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        #expect(abs(seconds - 1.0) < 0.1)
    }

    /// Translated speech arrives in bursts. The quiet between two replies
    /// is kept as silence, so the track stays on the session's timeline;
    /// the silence before anything was heard is not.
    @Test func translationRecordingKeepsTheGapBetweenReplies() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = SessionRecorder(id: UUID(), directory: directory)
        // What an idle microphone delivers before anyone speaks: not kept,
        // and the timeline does not start until there is sound.
        recorder.append(Data(count: 1_600 * 2), to: .original(.local))
        Thread.sleep(forTimeInterval: 0.5)
        let reply = Data(repeating: 0x40, count: 4_800 * 2) // 0.2 s at 24 kHz
        recorder.append(reply, to: .translation(.remote))
        Thread.sleep(forTimeInterval: 1)
        recorder.append(reply, to: .translation(.remote))
        recorder.finish()
        let file = try AVAudioFile(forReading: SessionHistory.recordingURL(
            for: recorder.id, track: .remoteTranslation, in: directory
        ))
        #expect(file.fileFormat.sampleRate == 24_000)
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        #expect(abs(seconds - 1.2) < 0.1)
        #expect(!FileManager.default.fileExists(atPath: SessionHistory.recordingURL(
            for: recorder.id, track: .local, in: directory
        ).path(percentEncoded: false)))
    }

    /// Helpers nested in an app bundle belong to that app, not to themselves.
    @Test func helperProcessesResolveToOutermostApp() {
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/140/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        #expect(AppOwnership.outermostApp(in: helper)?.path == "/Applications/Google Chrome.app")
        #expect(AppOwnership.outermostApp(in: "/usr/libexec/avconferenced") == nil)
    }
}
