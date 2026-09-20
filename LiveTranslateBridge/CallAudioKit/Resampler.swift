import AVFoundation
import Foundation

/// Converts captured audio into the 16 kHz mono 16-bit PCM that the translation
/// service expects.
///
/// Capture runs at the device rate (48 kHz, and stereo on the downlink) because
/// that is what Core Audio hands us untouched. The model's input layer is fixed
/// at 16 kHz mono, so the conversion happens here rather than at the capture
/// site, leaving the original stream available for playback or archiving.
nonisolated public final class Resampler: @unchecked Sendable {
    public static let targetSampleRate: Double = 16_000

    private let converter: AVAudioConverter
    private let sourceFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    private let lock = NSLock()

    public init(sourceFormat: AVAudioFormat) throws {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw CallAudioError("cannot build 16 kHz mono target format")
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        else {
            throw CallAudioError(
                "no conversion path from \(sourceFormat) to 16 kHz mono Int16"
            )
        }
        self.sourceFormat = sourceFormat
        self.targetFormat = targetFormat
        self.converter = converter
    }

    /// Returns little-endian Int16 samples, which is the wire format for
    /// `input_audio_buffer.append`.
    public func convert(_ buffer: AVAudioPCMBuffer) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        return try convertLocked(buffer)
    }

    /// The conversion itself. The caller holds `lock`, which guards the
    /// converter and both reused buffers.
    private func convertLocked(_ buffer: AVAudioPCMBuffer) throws -> Data {
        let ratio = Self.targetSampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(
            (Double(buffer.frameLength) * ratio).rounded(.up) + 64
        )
        // Reused across calls. Capture hands this the same frame count every
        // time, so after the first buffer the allocation never repeats — and
        // this runs on the Core Audio IO thread, where allocating is the kind
        // of unbounded-latency call that costs dropped frames.
        let output: AVAudioPCMBuffer
        if let reusable = outputBuffer, reusable.frameCapacity >= capacity {
            output = reusable
            // The converter writes `frameLength`, but a shorter result would
            // otherwise leave the previous call's tail readable behind it.
            output.frameLength = 0
        } else {
            guard let fresh = AVAudioPCMBuffer(
                pcmFormat: targetFormat, frameCapacity: capacity
            ) else {
                throw CallAudioError("cannot allocate conversion buffer")
            }
            outputBuffer = fresh
            output = fresh
        }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) {
            _, outStatus in
            // The converter pulls until it has enough input; feeding the same
            // buffer twice would duplicate audio, so report starvation instead.
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let conversionError {
            throw CallAudioError("resample failed: \(conversionError.localizedDescription)")
        }
        guard status != .error else {
            throw CallAudioError("resample returned an error status")
        }
        guard output.frameLength > 0, let channel = output.int16ChannelData else {
            return Data()
        }
        return Data(
            bytes: channel[0],
            count: Int(output.frameLength) * MemoryLayout<Int16>.size
        )
    }

    /// Wraps an interleaved float buffer from the process tap, which arrives as
    /// a raw pointer rather than an `AVAudioPCMBuffer`.
    ///
    /// The staging buffer is reused for the same reason as the output one:
    /// the tap delivers a steady frame count on a realtime thread, so
    /// building a format and a buffer per callback was pure per-frame
    /// allocation on the hottest path in the app.
    @available(macOS 14.2, *)
    public func convert(tapBuffer: DownlinkTap.Buffer) throws -> Data {
        let frames = AVAudioFrameCount(tapBuffer.frameCount)

        // Held for the copy *and* the conversion that reads it back: the
        // staging buffer is shared state, and handing it to `convert` after
        // releasing the lock would let a second callback overwrite the
        // samples mid-conversion.
        lock.lock()
        defer { lock.unlock() }

        // The tap's format is fixed for the life of the aggregate device, so
        // a mismatch here means the device changed under us and the cached
        // buffer describes the wrong stream.
        let reusable = stagingBuffer.flatMap { buffer -> AVAudioPCMBuffer? in
            guard buffer.format.sampleRate == tapBuffer.sampleRate,
                  buffer.format.channelCount
                      == AVAudioChannelCount(tapBuffer.channelCount),
                  buffer.frameCapacity >= frames else { return nil }
            return buffer
        }

        let staging: AVAudioPCMBuffer
        if let reusable {
            staging = reusable
        } else {
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: tapBuffer.sampleRate,
                channels: AVAudioChannelCount(tapBuffer.channelCount),
                interleaved: true
            ), let fresh = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: frames
            ) else {
                throw CallAudioError("cannot stage tap buffer for conversion")
            }
            stagingBuffer = fresh
            staging = fresh
        }
        staging.frameLength = frames
        let sampleCount = tapBuffer.frameCount * tapBuffer.channelCount
        staging.floatChannelData![0].update(
            from: tapBuffer.samples, count: sampleCount
        )

        return try convertLocked(staging)
    }

    /// The reused conversion output and tap staging buffers, both guarded by
    /// `lock` alongside the converter that reads and writes them.
    private var outputBuffer: AVAudioPCMBuffer?
    private var stagingBuffer: AVAudioPCMBuffer?
}
