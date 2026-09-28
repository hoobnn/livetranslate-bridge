import os
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
///
/// Reads the device through a HAL IOProc, as `DownlinkTap` reads its
/// aggregate, rather than through `AVAudioEngine`. The engine's input node
/// exposes only the first stream of a device, so an aggregate's second and
/// later members never arrived, and after switching the unit to a
/// non-default device it kept the previous device's channel count. The IOProc
/// sees every stream in the device's own layout, on the realtime thread, at
/// the device's IO buffer size; and unlike two engines on one AUHAL, several
/// IOProcs share a device without starving each other.
nonisolated public final class UplinkCapture: @unchecked Sendable {
    private var deviceID: AudioDeviceID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private let lock = NSLock()

    /// Channels across every input stream, and the device's nominal rate.
    public private(set) var channelCount = 0
    public private(set) var sampleRate: Double = 0

    /// Called on the realtime IO thread with the device's own IO buffer
    /// (typically 512 frames, ~11 ms). Read once at `start()`.
    public var onBuffer: (@Sendable (CapturedAudio) -> Void)?

    public init() {}
    deinit { stop() }

    /// Opens `device`, or the system default input when nil.
    public func start(device: AudioInputDevice? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        guard ioProcID == nil else { return }
        guard case .granted = AudioCapturePermission.current else {
            throw CallAudioError(
                "no microphone permission (status: "
                + "\(AudioCapturePermission.rawDescription)); grant it in "
                + "System Settings > Privacy & Security > Microphone"
            )
        }

        let id = device?.id ?? AudioObject.value(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDefaultInputDevice,
            default: AudioDeviceID(0)
        )
        let name = device?.name ?? "(system default)"
        guard id != 0 else { throw CallAudioError("no input device available") }

        let streams = AudioObject.objectList(
            id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput
        )
        guard !streams.isEmpty else {
            throw CallAudioError("input device \(name) has no input streams")
        }
        // The IOProc receives each stream in its virtual format. Every device
        // the HAL presents today uses Float32 there; anything else would be
        // misread as floats, so refuse it outright.
        var channels = 0
        for stream in streams {
            let format = AudioObject.value(
                stream, kAudioStreamPropertyVirtualFormat,
                default: AudioStreamBasicDescription()
            )
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32, format.mChannelsPerFrame > 0 else {
                throw CallAudioError("unsupported input format on \(name): \(format)")
            }
            channels += Int(format.mChannelsPerFrame)
        }
        let rate = AudioObject.value(
            id, kAudioDevicePropertyNominalSampleRate, default: Float64(0)
        )
        guard rate > 0 else { throw CallAudioError("input device \(name) reports no sample rate") }

        let handler = onBuffer
        var procID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, id, nil) {
            _, inputData, _, _, _ in
            // No fixed channel count: an aggregate that gains or loses a
            // member mid-session changes shape before the route watcher has
            // rebuilt the session, and the buffers in between are still
            // speech. Each buffer is bounds-checked on its own layout.
            guard let handler, let buffer = CapturedAudio(
                buffers: inputData, sampleRate: rate
            ) else { return }
            handler(buffer)
        }
        guard createStatus == noErr, let procID else {
            throw CallAudioError.status("AudioDeviceCreateIOProcID on \(name)", createStatus)
        }
        Self.disableOutput(of: procID, on: id)

        let startStatus = AudioDeviceStart(id, procID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(id, procID)
            throw CallAudioError.status("AudioDeviceStart on \(name)", startStatus)
        }
        deviceID = id
        ioProcID = procID
        channelCount = channels
        sampleRate = rate
        BridgeLog.tap.notice(
            "uplink capture bound to \(name, privacy: .public): \(rate, privacy: .public) Hz, \(streams.count, privacy: .public) stream(s), \(channels, privacy: .public) ch"
        )
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let procID = ioProcID else { return }
        AudioDeviceStop(deviceID, procID)
        AudioDeviceDestroyIOProcID(deviceID, procID)
        ioProcID = nil
        deviceID = 0
        channelCount = 0
        sampleRate = 0
    }

    /// A duplex device (a headset, an interface) would otherwise hand this
    /// proc its output streams too. It never writes them, so tell the HAL not
    /// to run them for it. Best effort: a device that refuses still works.
    private static func disableOutput(of procID: AudioDeviceIOProcID, on device: AudioDeviceID) {
        var address = AudioObject.address(
            kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeOutput
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioHardwareIOProcStreamUsage>.size) else { return }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment
        )
        defer { raw.deallocate() }
        let usage = raw.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        usage.pointee.mIOProc = unsafeBitCast(procID, to: UnsafeMutableRawPointer.self)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return }
        let count = Int(usage.pointee.mNumberStreams)
        // `mStreamIsOn` is a C flexible array: one flag per stream, laid out
        // past the end of the struct Swift sees. Written through the raw
        // buffer at the field's offset, never through a Swift copy of it.
        guard count > 0,
              let offset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn),
              offset + count * MemoryLayout<UInt32>.size <= Int(size) else { return }
        (raw + offset).assumingMemoryBound(to: UInt32.self).update(repeating: 0, count: count)
        AudioObjectSetPropertyData(device, &address, 0, nil, size, raw)
    }
}
