import AppKit
import CoreAudio
import Foundation

/// A running process whose output Core Audio can expose through a process tap.
/// The bundle identifier is stable across relaunches; pids and audio object ids
/// are deliberately resolved only when a session starts.
nonisolated public struct AudioSourceApplication: Identifiable, Hashable, Sendable {
    public let bundleID: String
    public let name: String
    public let isProducingAudio: Bool

    public var id: String { bundleID }

    public static func available() -> [AudioSourceApplication] {
        let ownBundleID = Bundle.main.bundleIdentifier
        var byBundleID: [String: AudioSourceApplication] = [:]

        for objectID in AudioObject.objectList(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyProcessObjectList
        ) {
            guard let bundleID = AudioObject.string(
                objectID, kAudioProcessPropertyBundleID
            ), !bundleID.isEmpty, bundleID != ownBundleID else { continue }

            let pid = AudioObject.value(
                objectID, kAudioProcessPropertyPID, default: pid_t(-1)
            )
            let running = NSRunningApplication(processIdentifier: pid)
            let name = running?.localizedName
                ?? running?.bundleURL?.deletingPathExtension().lastPathComponent
                ?? bundleID
            let producing = AudioObject.value(
                objectID, kAudioProcessPropertyIsRunningOutput,
                default: UInt32(0)
            ) == 1

            if let previous = byBundleID[bundleID] {
                byBundleID[bundleID] = AudioSourceApplication(
                    bundleID: bundleID,
                    name: previous.name,
                    isProducingAudio: previous.isProducingAudio || producing
                )
            } else {
                byBundleID[bundleID] = AudioSourceApplication(
                    bundleID: bundleID,
                    name: name,
                    isProducingAudio: producing
                )
            }
        }

        return byBundleID.values.sorted {
            if $0.isProducingAudio != $1.isProducingAudio {
                return $0.isProducingAudio && !$1.isProducingAudio
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
