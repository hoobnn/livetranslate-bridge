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

    /// Duplex capability alone does not identify loopback: headsets and USB
    /// interfaces can also expose both input and output streams.
    public let hasOutputStreams: Bool

    /// Sub-devices when this is an aggregate, empty otherwise.
    public var members: [AudioDeviceMember] = []

    /// Duplex hardware is not necessarily a virtual loopback device. An
    /// aggregate counts as one when any member is: its name is the user's
    /// own, but a loopback inside it still hands our output back as input.
    public var isKnownLoopback: Bool {
        AudioDeviceMember.isLoopbackLabel(name + " " + (uid ?? ""))
            || members.contains(where: \.isKnownLoopback)
    }

    /// Every UID through which this input could read back a loopback's
    /// output: its own when it is one, and each loopback member's.
    public var loopbackUIDs: Set<String> {
        var uids = Set(members.filter(\.isKnownLoopback).map(\.uid))
        if let uid, AudioDeviceMember.isLoopbackLabel(name + " " + uid) { uids.insert(uid) }
        return uids
    }

    /// The private aggregate `DownlinkTap` wraps its tap in. Visible to this
    /// process while a session runs, and never a microphone.
    private static let tapAggregatePrefix = "call-audio-bridge-agg"

    /// Every device that can record, in the order Core Audio lists them.
    public static func inputs() -> [AudioInputDevice] {
        AudioObject.objectList(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDevices
        ).compactMap { device in
            guard streamCount(device, scope: kAudioObjectPropertyScopeInput) > 0
            else { return nil }
            let uid = AudioObject.string(device, kAudioDevicePropertyDeviceUID)
            if uid?.hasPrefix(tapAggregatePrefix) == true { return nil }
            return AudioInputDevice(
                id: device,
                name: AudioObject.string(device, kAudioObjectPropertyName)
                    ?? "Device \(device)",
                uid: uid,
                hasOutputStreams: streamCount(
                    device, scope: kAudioObjectPropertyScopeOutput
                ) > 0,
                members: AudioObject.aggregateMembers(device)
            )
        }
    }

    /// Resolves a stored UID back to a live device. A saved choice is a UID
    /// because devices come and go. Nil means unresolved; the caller must
    /// distinguish an empty preference from a disconnected explicit device.
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
