import CoreAudio
import Foundation

/// An output device the synthesised translation can be played into.
///
/// The interesting case is not the speakers. Continuity relay reads our side of
/// the call from the *system default input*, so the only way to put translated
/// speech on the wire is to play it into a loopback device (BlackHole, Loopback,
/// Soundflower) that the user has also selected as that default input. The app
/// cannot install such a device itself — a HAL plug-in lives in
/// `/Library/Audio/Plug-Ins/HAL` and needs its own signing and an admin install
/// — so it enumerates what is there and lets the user point at one.
nonisolated public struct AudioOutputDevice: Identifiable, Hashable, Sendable {
    public let id: AudioDeviceID
    public let name: String
    public let uid: String?

    /// Whether this device also presents input streams. A plain loudspeaker
    /// does not; a loopback device does, because its whole purpose is to hand
    /// what is written to it back as a recordable input.
    public let hasInputStreams: Bool

    /// Loopback devices are the ones worth recommending for the uplink, and
    /// they are recognisable by having both directions. The name check is not
    /// load-bearing — it only sharpens the hint for the well-known ones.
    public var isLoopbackCandidate: Bool {
        guard hasInputStreams else { return false }
        let lowered = name.lowercased()
        if lowered.contains("blackhole") || lowered.contains("loopback")
            || lowered.contains("soundflower") || lowered.contains("virtual") {
            return true
        }
        // An aggregate of a real mic and a real speaker also reports both
        // directions; keep it, since it may still be the right target.
        return true
    }

    /// Every device that can play audio, in the order Core Audio lists them.
    public static func outputs() -> [AudioOutputDevice] {
        AudioObject.objectList(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDevices
        ).compactMap { device in
            guard streamCount(device, scope: kAudioObjectPropertyScopeOutput) > 0
            else { return nil }
            return AudioOutputDevice(
                id: device,
                name: AudioObject.string(device, kAudioObjectPropertyName)
                    ?? "Device \(device)",
                uid: AudioObject.string(device, kAudioDevicePropertyDeviceUID),
                hasInputStreams: streamCount(
                    device, scope: kAudioObjectPropertyScopeInput
                ) > 0
            )
        }
    }

    /// Resolves a stored UID back to a live device. Devices come and go — a USB
    /// interface is unplugged, BlackHole is uninstalled — so a saved choice is
    /// a UID, and a missing one falls back to the system default rather than
    /// failing the session.
    public static func named(uid: String?) -> AudioOutputDevice? {
        guard let uid, !uid.isEmpty else { return nil }
        return outputs().first { $0.uid == uid }
    }

    public static var systemDefault: AudioOutputDevice? {
        let id = AudioObject.value(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDefaultOutputDevice,
            default: AudioDeviceID(0)
        )
        guard id != 0 else { return nil }
        return outputs().first { $0.id == id }
    }

    /// The device Continuity would currently read our microphone from. Shown in
    /// the UI so the user can see at a glance whether their loopback device is
    /// actually selected as the input.
    public static var systemDefaultInputName: String? {
        let id = AudioObject.value(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDefaultInputDevice,
            default: AudioDeviceID(0)
        )
        guard id != 0 else { return nil }
        return AudioObject.string(id, kAudioObjectPropertyName)
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
