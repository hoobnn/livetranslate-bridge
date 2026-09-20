import CoreAudio
import Foundation

/// An input device our own side of the call can be captured from.
///
/// `UplinkCapture` used to follow the system default input, which is the one
/// device Continuity relay also reads. That is a single slot with two claimants:
/// pointing it at a loopback device so the far end hears the translation left
/// the app capturing that same loopback — its own synthesised speech, fed back
/// in and translated again. Binding the capture to a device explicitly is what
/// separates the two, so the loopback can serve the call while we keep the
/// real microphone.
nonisolated public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    public let id: AudioDeviceID
    public let name: String
    public let uid: String?

    /// Whether this device also presents output streams. Loopback devices do;
    /// a real microphone does not. Capturing one of these is what causes the
    /// feedback loop described above, so the UI marks them as a warning rather
    /// than a recommendation — the inverse of `AudioOutputDevice`.
    public let hasOutputStreams: Bool

    /// Every device that can record, in the order Core Audio lists them.
    public static func inputs() -> [AudioInputDevice] {
        AudioObject.objectList(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDevices
        ).compactMap { device in
            guard streamCount(device, scope: kAudioObjectPropertyScopeInput) > 0
            else { return nil }
            return AudioInputDevice(
                id: device,
                name: AudioObject.string(device, kAudioObjectPropertyName)
                    ?? "Device \(device)",
                uid: AudioObject.string(device, kAudioDevicePropertyDeviceUID),
                hasOutputStreams: streamCount(
                    device, scope: kAudioObjectPropertyScopeOutput
                ) > 0
            )
        }
    }

    /// Resolves a stored UID back to a live device. A saved choice is a UID
    /// because devices come and go; a missing one falls back to the system
    /// default rather than failing the session.
    public static func named(uid: String?) -> AudioInputDevice? {
        guard let uid, !uid.isEmpty else { return nil }
        return inputs().first { $0.uid == uid }
    }

    public static var systemDefault: AudioInputDevice? {
        let id = AudioObject.value(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDefaultInputDevice,
            default: AudioDeviceID(0)
        )
        guard id != 0 else { return nil }
        return inputs().first { $0.id == id }
    }

    private static func streamCount(
        _ device: AudioDeviceID, scope: AudioObjectPropertyScope
    ) -> Int {
        var addr = AudioObject.address(
            kAudioDevicePropertyStreams, scope: scope
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr
        else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }
}
