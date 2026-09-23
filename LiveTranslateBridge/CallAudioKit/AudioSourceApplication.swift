import AppKit
import CoreAudio
import Darwin
import Foundation

/// One Core Audio process object and the application it renders for.
///
/// Multi-process apps do not play from their main process: Chrome, Electron
/// apps (Lark, Teams, Slack) and QQ render from `*.helper` processes nested
/// inside the app bundle, and tapping the main process captures silence. The
/// owner is therefore the outermost `.app` around the executable, which is
/// where every nested helper lives.
nonisolated public struct AudioProcessObject: Sendable, Equatable {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String
    public let ownerBundleID: String
    public let ownerName: String?
    public let isRunningInput: Bool
    public let isRunningOutput: Bool

    public static func all() -> [AudioProcessObject] {
        AudioObject.objectList(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyProcessObjectList
        ).compactMap { objectID in
            guard let bundleID = AudioObject.string(objectID, kAudioProcessPropertyBundleID),
                  !bundleID.isEmpty else { return nil }
            let pid = AudioObject.value(objectID, kAudioProcessPropertyPID, default: pid_t(-1))
            let owner = AppOwnership.owner(of: pid)
            return AudioProcessObject(
                objectID: objectID,
                pid: pid,
                bundleID: bundleID,
                ownerBundleID: owner?.bundleID ?? bundleID,
                ownerName: owner?.name,
                isRunningInput: AudioObject.value(
                    objectID, kAudioProcessPropertyIsRunningInput, default: UInt32(0)) == 1,
                isRunningOutput: AudioObject.value(
                    objectID, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) == 1
            )
        }
    }

    /// Every process object rendering for `bundleID`, including nested helpers.
    public static func owned(by bundleID: String) -> [AudioProcessObject] {
        all().filter { $0.ownerBundleID == bundleID }
    }
}

/// Maps a pid to the outermost enclosing app bundle. Cached by executable path
/// because the Info.plist read is the expensive part and paths do not move.
nonisolated enum AppOwnership {
    struct Owner: Sendable { let bundleID: String; let name: String }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Owner?] = [:]

    static func owner(of pid: pid_t) -> Owner? {
        guard pid > 0, let path = executablePath(pid) else { return nil }
        lock.lock()
        if let cached = cache[path] { lock.unlock(); return cached }
        lock.unlock()
        let resolved = outermostApp(in: path).flatMap { url -> Owner? in
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
            let name = FileManager.default.displayName(atPath: url.path)
            return Owner(bundleID: id, name: (name as NSString).deletingPathExtension)
        }
        lock.lock()
        cache[path] = resolved
        lock.unlock()
        return resolved
    }

    static func outermostApp(in path: String) -> URL? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return URL(fileURLWithPath: "/" + components[...index].joined(separator: "/"))
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}

/// A running application whose output Core Audio can expose through a process
/// tap. The bundle identifier is the owning app's and is stable across
/// relaunches; helper bundle IDs and object ids are resolved per session.
nonisolated public struct AudioSourceApplication: Identifiable, Hashable, Sendable {
    public let bundleID: String
    public let name: String
    public let isProducingAudio: Bool

    public var id: String { bundleID }

    public static func available() -> [AudioSourceApplication] {
        let ownBundleID = Bundle.main.bundleIdentifier
        var byBundleID: [String: AudioSourceApplication] = [:]

        for process in AudioProcessObject.all() where process.ownerBundleID != ownBundleID {
            let key = process.ownerBundleID
            let producing = process.isRunningOutput
            if let previous = byBundleID[key] {
                byBundleID[key] = AudioSourceApplication(
                    bundleID: key,
                    name: previous.name,
                    isProducingAudio: previous.isProducingAudio || producing
                )
            } else {
                let running = NSRunningApplication.runningApplications(withBundleIdentifier: key).first
                    ?? NSRunningApplication(processIdentifier: process.pid)
                let name = running?.localizedName ?? process.ownerName ?? key
                byBundleID[key] = AudioSourceApplication(
                    bundleID: key, name: name, isProducingAudio: producing
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

    /// The bundle IDs a tap must follow to hear `bundleID`: the app itself and
    /// every helper currently rendering for it. The tap restores these by
    /// bundle ID when processes relaunch, so pids never need tracking.
    public static func tapBundleIDs(for bundleID: String) -> [String] {
        var ids = [bundleID]
        for process in AudioProcessObject.owned(by: bundleID) where !ids.contains(process.bundleID) {
            ids.append(process.bundleID)
        }
        return ids
    }
}
