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
        var sampleRate: Double = 0
        var channelCount = 0
        var frameCount = 0
        var interleaved = false

        deinit { storage.deallocate() }
    }

    private let slots = (0..<slotCount).map { _ in Slot() }
    private let readIndex = Atomic<Int>(0)
    private let writeIndex = Atomic<Int>(0)
    private let dropped = Atomic<Int>(0)
    private let workerQueue: DispatchQueue
    private let source: DispatchSourceUserDataAdd
    private let handler: Handler
    private let dropHandler: DropHandler
    private var stagingBuffer: AVAudioPCMBuffer?

    init(
        label: String,
        handler: @escaping Handler,
        onDrop: @escaping DropHandler
    ) {
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

    /// Runs lifecycle work on the same serial queue as conversion.
    func perform(_ work: @escaping @Sendable () -> Void) {
        workerQueue.async(execute: work)
    }

    @available(macOS 14.2, *)
    func enqueue(_ buffer: DownlinkTap.Buffer) {
        let sampleCount = buffer.frameCount * buffer.channelCount
        enqueue(
            sampleRate: buffer.sampleRate,
            channelCount: buffer.channelCount,
            frameCount: buffer.frameCount,
            interleaved: true,
            sampleCount: sampleCount
        ) { destination in
            destination.copyMemory(
                from: UnsafeRawPointer(buffer.samples),
                byteCount: sampleCount * MemoryLayout<Float>.size
            )
        }
    }

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let channels = buffer.floatChannelData else {
            recordDrop()
            return
        }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let interleaved = buffer.format.isInterleaved
        let sampleCount = frameCount * channelCount
        enqueue(
            sampleRate: buffer.format.sampleRate,
            channelCount: channelCount,
            frameCount: frameCount,
            interleaved: interleaved,
            sampleCount: sampleCount
        ) { destination in
            if interleaved {
                destination.copyMemory(
                    from: UnsafeRawPointer(channels[0]),
                    byteCount: sampleCount * MemoryLayout<Float>.size
                )
            } else {
                let channelBytes = frameCount * MemoryLayout<Float>.size
                for channel in 0..<channelCount {
                    destination.advanced(by: channel * channelBytes).copyMemory(
                        from: UnsafeRawPointer(channels[channel]),
                        byteCount: channelBytes
                    )
                }
            }
        }
    }

    private func enqueue(
        sampleRate: Double,
        channelCount: Int,
        frameCount: Int,
        interleaved: Bool,
        sampleCount: Int,
        copy: (UnsafeMutableRawPointer) -> Void
    ) {
        let byteCount = sampleCount * MemoryLayout<Float>.size
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
        copy(slot.storage)
        slot.sampleRate = sampleRate
        slot.channelCount = channelCount
        slot.frameCount = frameCount
        slot.interleaved = interleaved
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
            if let buffer = makeBuffer(from: slot) { handler(buffer) }
            read = (read + 1) % Self.slotCount
            readIndex.store(read, ordering: .releasing)
        }
    }

    private func makeBuffer(from slot: Slot) -> AVAudioPCMBuffer? {
        let channels = AVAudioChannelCount(slot.channelCount)
        let frames = AVAudioFrameCount(slot.frameCount)
        let reusable = stagingBuffer.flatMap { buffer -> AVAudioPCMBuffer? in
            guard buffer.format.sampleRate == slot.sampleRate,
                  buffer.format.channelCount == channels,
                  buffer.format.isInterleaved == slot.interleaved,
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
                interleaved: slot.interleaved
            ), let fresh = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
            else { return nil }
            stagingBuffer = fresh
            buffer = fresh
        }

        buffer.frameLength = frames
        guard let destination = buffer.floatChannelData else { return nil }
        if slot.interleaved {
            destination[0].update(
                from: slot.storage.assumingMemoryBound(to: Float.self),
                count: slot.frameCount * slot.channelCount
            )
        } else {
            let channelBytes = slot.frameCount * MemoryLayout<Float>.size
            for channel in 0..<slot.channelCount {
                destination[channel].update(
                    from: slot.storage.advanced(by: channel * channelBytes)
                        .assumingMemoryBound(to: Float.self),
                    count: slot.frameCount
                )
            }
        }
        return buffer
    }
}
