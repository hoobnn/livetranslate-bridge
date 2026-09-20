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
    private var installed = false

    public private(set) var format: AVAudioFormat?
    public var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

    public init() {}
    deinit { stop() }

    /// Opens the engine against `device`, or the system default when nil.
    public func start(device: AudioInputDevice? = nil) throws {
        guard !installed else { return }
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

        let tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = {
            [weak self] buffer, _ in
            self?.onBuffer?(buffer)
        }
        // macOS 27 deprecated the non-throwing `installTap` in favour of a
        // variant that reports why a tap was refused instead of trapping. It
        // ships `NS_REFINED_FOR_SWIFT` with no overlay in the 27.0 SDK, so the
        // only spelling available is the underscored one, whose `error:` slot
        // imports as `()` and surfaces through `throws`. Ugly, but it is the
        // non-deprecated path; swap it for `installTap(...) throws` once the
        // SDK exposes a refined wrapper.
        //
        // The new API documents a supported buffer range of [100, 400] ms,
        // and the old 2048 frames was 43 ms at 48 kHz — under that floor. Ask
        // for the low end of the range so latency stays as close to the old
        // behaviour as the contract allows, computed from the device's own
        // rate rather than assuming 48 kHz.
        let bufferSize = AVAudioFrameCount(inputFormat.sampleRate / 10)
        do {
            try input.__installTap(
                onBus: 0, bufferSize: bufferSize, format: inputFormat,
                error: (), block: tap
            )
        } catch {
            throw CallAudioError("cannot install microphone tap: \(error)")
        }
        installed = true

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            installed = false
            throw CallAudioError("cannot start audio engine: \(error)")
        }
    }

    public func stop() {
        guard installed else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        installed = false
        format = nil
    }
}
