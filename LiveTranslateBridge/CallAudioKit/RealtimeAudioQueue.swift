import Accelerate
import AVFoundation
import Dispatch
import Foundation
import Synchronization

/// A single-producer/single-consumer ring used at the Core Audio boundary.
///
/// The producer performs no allocation, locking, conversion, logging or
/// networking. It only copies Float32 samples into storage allocated at init
/// and publishes the slot with release ordering. The worker rebuilds an
/// `AVAudioPCMBuffer` and performs all expensive work off the IO thread.
///
/// Slots always hold one contiguous run per channel, whatever layout the
/// callback used, so the consumer has a single shape to rebuild.
nonisolated final class RealtimeAudioQueue: @unchecked Sendable {
    typealias Handler = @Sendable (AVAudioPCMBuffer) -> Void
    typealias DropHandler = @Sendable (Int) -> Void

    private static let slotCount = 16
    private static let slotBytes = 256 * 1024

    private final class Slot: @unchecked Sendable {
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: RealtimeAudioQueue.slotBytes,
            alignment: MemoryLayout<Float>.alignment
        )
        var epoch = 0
        var enqueuedAt: UInt64 = 0
        var sampleRate: Double = 0
        var channelCount = 0
        var frameCount = 0

        deinit { storage.deallocate() }
    }

    private let slots = (0..<slotCount).map { _ in Slot() }
    private let readIndex = Atomic<Int>(0)
    private let writeIndex = Atomic<Int>(0)
    private let dropped = Atomic<Int>(0)
    private let epoch = Atomic<Int>(0)
    private let workerQueue: DispatchQueue
    private let source: DispatchSourceUserDataAdd
    private let maximumAge: UInt64
    private let handler: Handler
    private let dropHandler: DropHandler
    private var stagingBuffer: AVAudioPCMBuffer?
    /// The fold's gain at the end of the last block; worker-only.
    private var foldGain: Float = 1
    /// Per channel, frames since it last reached `liveChannelPeak`; worker-only.
    private var framesSinceLoud: [Int] = []
    /// −50 dBFS: well above an idle input's noise, below quiet speech peaks.
    private static let liveChannelPeak: Float = 0.003_2
    /// How long a channel stays live after its last loud block, in seconds.
    private static let liveChannelHold = 0.5

    init(
        label: String,
        maximumAge: Double = 0.5,
        handler: @escaping Handler,
        onDrop: @escaping DropHandler
    ) {
        self.maximumAge = UInt64(maximumAge * 1_000_000_000)
        self.handler = handler
        self.dropHandler = onDrop
        let queue = DispatchQueue(label: label, qos: .userInitiated)
        workerQueue = queue
        source = DispatchSource.makeUserDataAddSource(queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.resume()
    }

    deinit {
        source.setEventHandler {}
        source.cancel()
    }

    func invalidate() { _ = epoch.wrappingAdd(1, ordering: .acquiringAndReleasing) }

    /// Runs lifecycle work on the same serial queue as conversion.
    func perform(_ work: @escaping @Sendable () -> Void) {
        workerQueue.async(execute: work)
    }

    /// Copies a realtime capture callback's buffers, splitting each
    /// buffer's interleaved channels into their own runs.
    func enqueue(_ buffer: CapturedAudio) {
        let frames = buffer.frameCount
        enqueue(
            sampleRate: buffer.sampleRate,
            channelCount: buffer.channelCount,
            frameCount: frames
        ) { destination in
            let list = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: buffer.buffers)
            )
            var channel = 0
            for source in list {
                let samples = source.mData!.assumingMemoryBound(to: Float.self)
                let width = Int(source.mNumberChannels)
                for offset in 0..<width {
                    Self.copy(samples + offset, stride: width, frames: frames,
                              into: destination + channel * frames)
                    channel += 1
                }
            }
        }
    }

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let channels = buffer.floatChannelData else {
            recordDrop()
            return
        }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let interleaved = buffer.format.isInterleaved
        enqueue(
            sampleRate: buffer.format.sampleRate,
            channelCount: channelCount,
            frameCount: frames
        ) { destination in
            for channel in 0..<channelCount {
                Self.copy(
                    interleaved ? channels[0] + channel : channels[channel],
                    stride: interleaved ? channelCount : 1,
                    frames: frames,
                    into: destination + channel * frames
                )
            }
        }
    }

    /// One channel out of a possibly interleaved run. Realtime-safe.
    private static func copy(_ source: UnsafePointer<Float>, stride: Int, frames: Int,
                             into destination: UnsafeMutablePointer<Float>) {
        if stride == 1 {
            destination.update(from: source, count: frames)
        } else {
            cblas_scopy(Int32(frames), source, Int32(stride), destination, 1)
        }
    }

    private func enqueue(
        sampleRate: Double,
        channelCount: Int,
        frameCount: Int,
        copy: (UnsafeMutablePointer<Float>) -> Void
    ) {
        let producerEpoch = epoch.load(ordering: .acquiring)
        let byteCount = frameCount * channelCount * MemoryLayout<Float>.size
        guard sampleRate > 0, channelCount > 0, frameCount > 0,
              byteCount <= Self.slotBytes else {
            recordDrop()
            return
        }

        let write = writeIndex.load(ordering: .relaxed)
        let next = (write + 1) % Self.slotCount
        guard next != readIndex.load(ordering: .acquiring) else {
            recordDrop()
            return
        }

        let slot = slots[write]
        copy(slot.storage.assumingMemoryBound(to: Float.self))
        slot.epoch = producerEpoch
        slot.enqueuedAt = DispatchTime.now().uptimeNanoseconds
        slot.sampleRate = sampleRate
        slot.channelCount = channelCount
        slot.frameCount = frameCount
        writeIndex.store(next, ordering: .releasing)
        source.add(data: 1)
    }

    private func recordDrop() {
        _ = dropped.wrappingAdd(1, ordering: .relaxed)
        source.add(data: 1)
    }

    private func drain() {
        let dropCount = dropped.exchange(0, ordering: .acquiringAndReleasing)
        if dropCount > 0 { dropHandler(dropCount) }

        var read = readIndex.load(ordering: .relaxed)
        let write = writeIndex.load(ordering: .acquiring)
        while read != write {
            let slot = slots[read]
            if slot.epoch == epoch.load(ordering: .acquiring),
               DispatchTime.now().uptimeNanoseconds - slot.enqueuedAt <= maximumAge {
                if let buffer = makeBuffer(from: slot) { handler(buffer) } else { dropHandler(1) }
            } else {
                dropHandler(1)
            }
            read = (read + 1) % Self.slotCount
            readIndex.store(read, ordering: .releasing)
        }
    }

    /// Rebuilds the slot as a buffer the rest of the pipeline can convert.
    ///
    /// More than two channels — a multichannel interface or an aggregate
    /// device — are folded to mono here. `AVAudioFormat` has no layout-free
    /// form beyond stereo (the initialiser returns nil), and with a discrete
    /// layout `AVAudioConverter` has no idea where the channels go and
    /// renders silence.
    ///
    /// The fold averages over the channels that carry sound, not over all of
    /// them: a microphone on one input of four keeps its full level instead
    /// of losing 12 dB to three idle inputs, and the same programme on two
    /// inputs — a stereo loopback inside an aggregate — stays at unity
    /// instead of summing into clipping.
    ///
    /// "Carries sound" has hysteresis: a channel joins above −50 dBFS and
    /// leaves only after half a second without reaching it. An idle preamp
    /// whose noise hovers near a single threshold would otherwise flip in and
    /// out every block and put a 6 dB tremolo on the voice. The gain ramps
    /// across the block, so a real change of speakers is click-free.
    private func makeBuffer(from slot: Slot) -> AVAudioPCMBuffer? {
        let folds = slot.channelCount > 2
        let channels = AVAudioChannelCount(folds ? 1 : slot.channelCount)
        let frames = AVAudioFrameCount(slot.frameCount)
        let reusable = stagingBuffer.flatMap { buffer -> AVAudioPCMBuffer? in
            guard buffer.format.sampleRate == slot.sampleRate,
                  buffer.format.channelCount == channels,
                  buffer.frameCapacity >= frames else { return nil }
            return buffer
        }

        let buffer: AVAudioPCMBuffer
        if let reusable {
            buffer = reusable
        } else {
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: slot.sampleRate,
                channels: channels,
                interleaved: false
            ), let fresh = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
            else { return nil }
            stagingBuffer = fresh
            buffer = fresh
        }

        buffer.frameLength = frames
        guard let destination = buffer.floatChannelData else { return nil }
        let samples = slot.storage.assumingMemoryBound(to: Float.self)
        if folds {
            let mono = destination[0]
            let length = vDSP_Length(slot.frameCount)
            if framesSinceLoud.count != slot.channelCount {
                framesSinceLoud = Array(repeating: Int.max / 2, count: slot.channelCount)
            }
            let hold = Int(Self.liveChannelHold * slot.sampleRate)
            var live = 0
            for channel in 0..<slot.channelCount {
                var peak: Float = 0
                vDSP_maxmgv(samples + channel * slot.frameCount, 1, &peak, length)
                framesSinceLoud[channel] = peak > Self.liveChannelPeak
                    ? 0 : framesSinceLoud[channel] + slot.frameCount
                if framesSinceLoud[channel] < hold { live += 1 }
            }
            mono.update(from: samples, count: slot.frameCount)
            for channel in 1..<slot.channelCount {
                vDSP_vadd(samples + channel * slot.frameCount, 1, mono, 1, mono, 1, length)
            }
            let gain = 1 / Float(max(live, 1))
            var start = foldGain
            var step = (gain - foldGain) / Float(slot.frameCount)
            vDSP_vrampmul(mono, 1, &start, &step, mono, 1, length)
            foldGain = gain
            var low: Float = -1, high: Float = 1
            vDSP_vclip(mono, 1, &low, &high, mono, 1, length)
        } else {
            for channel in 0..<slot.channelCount {
                destination[channel].update(
                    from: samples + channel * slot.frameCount,
                    count: slot.frameCount
                )
            }
        }
        return buffer
    }
}
