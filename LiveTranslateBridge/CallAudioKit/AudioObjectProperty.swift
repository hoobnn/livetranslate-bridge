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
        _ selector: AudioObjectPropertySelector
    ) -> [AudioObjectID] {
        var addr = address(selector)
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
