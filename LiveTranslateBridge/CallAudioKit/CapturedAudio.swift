import Accelerate
import CoreAudio

/// Float32 audio borrowed from a realtime capture callback. The pointers are
/// valid only for the duration of that callback, so consumers copy before
/// returning and never retain the value.
nonisolated public struct CapturedAudio: @unchecked Sendable {
    public let buffers: UnsafePointer<AudioBufferList>
    public let frameCount: Int
    public let channelCount: Int
    public let sampleRate: Double
    public let interleaved: Bool

    /// Validates the list against the declared layout so a device that changes
    /// shape mid-stream is dropped rather than read out of bounds.
    init?(buffers: UnsafePointer<AudioBufferList>, channelCount: Int,
          sampleRate: Double, interleaved: Bool) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffers))
        guard channelCount > 0, sampleRate > 0,
              list.count == (interleaved ? 1 : channelCount),
              let first = list.first, first.mData != nil else { return nil }
        let samplesPerFrame = interleaved ? channelCount : 1
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / samplesPerFrame
        guard frames > 0, list.allSatisfy({
            $0.mData != nil && Int($0.mDataByteSize) >= frames * samplesPerFrame * MemoryLayout<Float>.size
        }) else { return nil }
        self.buffers = buffers
        self.frameCount = frames
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.interleaved = interleaved
    }

    /// Absolute peak over every channel. Allocation-free, safe on the IO thread.
    public var peak: Float {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffers))
        var loudest: Float = 0
        for buffer in list {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            var value: Float = 0
            vDSP_maxmgv(data, 1, &value, vDSP_Length(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size))
            loudest = max(loudest, value)
        }
        return loudest
    }
}
