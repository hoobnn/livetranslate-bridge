import Foundation
import Synchronization

/// Deinterleaved Float32 ring between a serialized producer and the render
/// thread. The render side is lock- and allocation-free.
///
/// Indices grow monotonically; the fill level is `write - read`. Besides the
/// consumer, any thread may `discard` queued audio (a skip or a catch-up);
/// the consumer publishes its read with a compare-exchange so it never
/// rewinds past such a discard.
nonisolated final class AudioRing: @unchecked Sendable {
    let channelCount: Int
    let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let readIndex = Atomic<Int>(0)
    private let writeIndex = Atomic<Int>(0)

    init(channels: Int, capacity: Int) {
        channelCount = channels
        self.capacity = capacity
        storage = .allocate(capacity: channels * capacity)
        storage.initialize(repeating: 0, count: channels * capacity)
    }

    deinit { storage.deallocate() }

    var availableFrames: Int {
        let read = readIndex.load(ordering: .acquiring)
        return max(0, writeIndex.load(ordering: .acquiring) - read)
    }

    /// Producer. Writes as many frames as fit and returns that count.
    /// `source(channel)` must yield `frames` contiguous samples.
    @discardableResult
    func write(frames: Int, source: (Int) -> UnsafePointer<Float>) -> Int {
        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        let count = min(frames, capacity - (write - read))
        guard count > 0 else { return 0 }
        let start = write % capacity
        let head = min(count, capacity - start)
        for channel in 0..<channelCount {
            let from = source(channel)
            let lane = storage + channel * capacity
            (lane + start).update(from: from, count: head)
            if count > head { lane.update(from: from + head, count: count - head) }
        }
        writeIndex.store(write + count, ordering: .releasing)
        return count
    }

    /// Consumer. Copies up to `frames` into `destination(channel)` and returns
    /// the count copied.
    func read(frames: Int, into destination: (Int) -> UnsafeMutablePointer<Float>) -> Int {
        let read = readIndex.load(ordering: .acquiring)
        let count = min(frames, writeIndex.load(ordering: .acquiring) - read)
        guard count > 0 else { return 0 }
        let start = read % capacity
        let head = min(count, capacity - start)
        for channel in 0..<channelCount {
            let to = destination(channel)
            let lane = storage + channel * capacity
            to.update(from: lane + start, count: head)
            if count > head { (to + head).update(from: lane, count: count - head) }
        }
        _ = readIndex.compareExchange(
            expected: read, desired: read + count, ordering: .acquiringAndReleasing
        )
        return count
    }

    /// Drops everything but the newest `keeping` frames. Returns frames dropped.
    @discardableResult
    func discard(keeping: Int = 0) -> Int {
        var read = readIndex.load(ordering: .acquiring)
        while true {
            let target = max(read, writeIndex.load(ordering: .acquiring) - keeping)
            guard target > read else { return 0 }
            let result = readIndex.compareExchange(
                expected: read, desired: target, ordering: .acquiringAndReleasing
            )
            if result.exchanged { return target - read }
            read = result.original
        }
    }
}

/// A gain target handed from the control queue to the render thread.
nonisolated final class AtomicGain: @unchecked Sendable {
    private let bits: Atomic<UInt32>
    init(_ value: Float) { bits = Atomic(value.bitPattern) }
    var value: Float {
        get { Float(bitPattern: bits.load(ordering: .relaxed)) }
        set { bits.store(newValue.bitPattern, ordering: .relaxed) }
    }
}
