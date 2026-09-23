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
        // Without `downmix` a stereo → mono converter keeps channel 0 only, so
        // anything panned right (a meeting participant, a video's dialogue
        // track) never reached ASR. Downmix averages every channel instead.
        converter.downmix = true
        // Decimating 48 → 16 kHz: a steeper anti-alias filter keeps 8–24 kHz
        // content from folding into the speech band. The cost at 16 kHz mono
        // is negligible.
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
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
        // time, so after the first buffer the allocation never repeats.
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

    /// The reused conversion output buffer, guarded by `lock` alongside the
    /// converter that writes it.
    private var outputBuffer: AVAudioPCMBuffer?
}
