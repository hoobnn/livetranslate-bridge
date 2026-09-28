import Accelerate
import CoreAudio

/// Float32 audio borrowed from a realtime capture callback. The pointers are
/// valid only for the duration of that callback, so consumers copy before
/// returning and never retain the value.
///
/// The list is taken as Core Audio hands it over: one buffer per stream, each
/// interleaving its own `mNumberChannels`. A single interleaved stream and one
/// buffer per channel are the two common shapes; an aggregate device's input
/// is neither — several streams, each with several channels — and is read the
/// same way.
nonisolated public struct CapturedAudio: @unchecked Sendable {
    public let buffers: UnsafePointer<AudioBufferList>
    public let frameCount: Int
    /// Channels across every buffer, in buffer order.
    public let channelCount: Int
    public let sampleRate: Double

    /// Validates every buffer against a common frame count, so a device that
    /// changes shape mid-stream is dropped rather than read out of bounds.
    /// `expectedChannels`, when given, must match the list's total.
    init?(buffers: UnsafePointer<AudioBufferList>, sampleRate: Double,
          expectedChannels: Int? = nil) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffers))
        guard sampleRate > 0, let first = list.first, first.mNumberChannels > 0,
              list.allSatisfy({ $0.mData != nil && $0.mNumberChannels > 0 }) else { return nil }
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / Int(first.mNumberChannels)
        let channels = list.reduce(0) { $0 + Int($1.mNumberChannels) }
        guard frames > 0, expectedChannels.map({ $0 == channels }) ?? true,
              list.allSatisfy({
                  Int($0.mDataByteSize) >= frames * Int($0.mNumberChannels) * MemoryLayout<Float>.size
              }) else { return nil }
        self.buffers = buffers
        self.frameCount = frames
        self.channelCount = channels
        self.sampleRate = sampleRate
    }

    /// Absolute peak over every channel. Allocation-free, safe on the IO thread.
    public var peak: Float {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffers))
        var loudest: Float = 0
        for buffer in list {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            var value: Float = 0
            let samples = frameCount * Int(buffer.mNumberChannels)
            vDSP_maxmgv(data, 1, &value, vDSP_Length(samples))
            loudest = max(loudest, value)
        }
        return loudest
    }
}
