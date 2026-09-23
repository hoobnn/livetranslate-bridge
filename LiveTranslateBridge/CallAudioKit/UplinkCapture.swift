import os
import AVFoundation
import CoreAudio
import Foundation

/// Captures our own side of the call from a chosen input device.
///
/// This is deliberately separate from `DownlinkTap`: a process tap only carries
/// a process's *output*, so the microphone never appears in it. Measured on a
/// live call, the two streams correlate at r≈0.19 — the residue is the speaker
/// bleeding into the mic, not mixed signal.
///
/// The device is chosen explicitly rather than followed from the system
/// default. Continuity relay reads the uplink from that default input, so a
/// user who points it at a loopback device to let the far end hear their
/// translation would otherwise have this capture read the loopback too —
/// swallowing its own synthesised speech and translating it again. Naming the
/// microphone here keeps the two apart. See `AudioInputDevice`.
nonisolated public final class UplinkCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var sink: AVAudioSinkNode?

    public private(set) var format: AVAudioFormat?
    /// Called on the realtime IO thread with the device's own IO buffer
    /// (typically 512 frames, ~11 ms). Read once at `start()`.
    public var onBuffer: (@Sendable (CapturedAudio) -> Void)?

    public init() {}
    deinit { stop() }

    /// Opens the engine against `device`, or the system default when nil.
    public func start(device: AudioInputDevice? = nil) throws {
        guard sink == nil else { return }
        guard case .granted = AudioCapturePermission.current else {
            throw CallAudioError(
                "no microphone permission (status: "
                + "\(AudioCapturePermission.rawDescription)); grant it in "
                + "System Settings > Privacy & Security > Microphone"
            )
        }
        let input = engine.inputNode

        // Selecting the device has to happen on the input audio unit before the
        // format is read: `AVAudioEngine` has no device property of its own on
        // macOS, and `outputFormat(forBus:)` reports the *current* device, so
        // reading it first would capture the format of the wrong one.
        if let device {
            // Mirrors `TranslationPlayer`: the device is set on the unit
            // itself, in the global scope, which is where the AUHAL keeps it.
            var status = OSStatus(kAudioUnitErr_InvalidElement)
            input.withAudioUnit { unit in
                guard let unit else { return }
                var deviceID = device.id
                status = AudioUnitSetProperty(
                    unit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &deviceID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
            }
            guard status == noErr else {
                throw CallAudioError.status(
                    "selecting input device \(device.name)", status
                )
            }
            BridgeLog.tap.notice(
                "uplink capture bound to \(device.name, privacy: .public)"
            )
        }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw CallAudioError(
                "input device \(device?.name ?? "(system default)") reports no format"
            )
        }
        format = inputFormat

        // A sink node receives the input unit's IO buffers on the realtime
        // thread as they arrive. `installTap` instead batches into blocks of
        // at least 100 ms on a non-realtime thread, which held the end of
        // every utterance back from the service by that much.
        let handler = onBuffer
        let channels = Int(inputFormat.channelCount)
        let sampleRate = inputFormat.sampleRate
        let interleaved = inputFormat.isInterleaved
        let sink = AVAudioSinkNode { _, _, list in
            if let handler, let buffer = CapturedAudio(
                buffers: list, channelCount: channels,
                sampleRate: sampleRate, interleaved: interleaved
            ) { handler(buffer) }
            return noErr
        }
        engine.attach(sink)
        engine.connect(input, to: sink, format: inputFormat)
        self.sink = sink

        do {
            try engine.start()
        } catch {
            engine.detach(sink)
            self.sink = nil
            throw CallAudioError("cannot start audio engine: \(error)")
        }
    }

    public func stop() {
        guard let sink else { return }
        engine.stop()
        engine.detach(sink)
        self.sink = nil
        format = nil
    }
}
