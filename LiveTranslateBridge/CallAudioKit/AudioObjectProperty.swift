import CoreAudio
import Foundation

/// Thin typed wrappers over the AudioObject property API, which is otherwise
/// four lines of pointer juggling per read.
nonisolated enum AudioObject {
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func value<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        default fallback: T
    ) -> T {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        var result = fallback
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? result : fallback
    }

    static func string(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    static func objectList(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [AudioObjectID] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioObjectID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    /// Channels across every stream in `scope`. `kAudioDevicePropertyStreamFormat`
    /// describes only the first stream, which for an aggregate is one member.
    static func channelCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// The devices an aggregate (or multi-output device) is built from, empty
    /// for anything else. Active members only: a disconnected sub-device
    /// contributes no streams and cannot carry audio either way.
    static func aggregateMembers(_ device: AudioObjectID) -> [AudioDeviceMember] {
        objectList(device, kAudioAggregateDevicePropertyActiveSubDeviceList).compactMap { member in
            guard let uid = string(member, kAudioDevicePropertyDeviceUID) else { return nil }
            return AudioDeviceMember(
                uid: uid, name: string(member, kAudioObjectPropertyName) ?? uid
            )
        }
    }

    /// OSStatus values are usually four-character codes; decimal alone is useless.
    static func describe(_ status: OSStatus) -> String {
        var bigEndian = status.bigEndian
        let chars = withUnsafeBytes(of: &bigEndian) { raw in
            raw.map { byte -> Character in
                (byte >= 32 && byte < 127) ? Character(UnicodeScalar(byte)) : "?"
            }
        }
        return "\(status) ('\(String(chars))')"
    }
}

nonisolated public struct CallAudioError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }

    static func status(_ what: String, _ status: OSStatus) -> CallAudioError {
        CallAudioError("\(what) failed: \(AudioObject.describe(status))")
    }
}

/// One device inside an aggregate.
nonisolated public struct AudioDeviceMember: Hashable, Sendable {
    public let uid: String
    public let name: String

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }

    var isKnownLoopback: Bool { AudioDeviceMember.isLoopbackLabel(name + " " + uid) }

    /// The virtual loopback drivers this app knows by name. Duplex hardware
    /// (headsets, USB interfaces) also exposes input and output streams, so
    /// capability alone does not identify one.
    static func isLoopbackLabel(_ label: String) -> Bool {
        let lowered = label.lowercased()
        return ["blackhole", "loopback", "soundflower"].contains { lowered.contains($0) }
    }
}
