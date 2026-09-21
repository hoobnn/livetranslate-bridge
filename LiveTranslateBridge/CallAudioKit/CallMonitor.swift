import os
import CoreAudio
import Foundation

/// The default source retained for existing installs. Users can replace it
/// with any process registered with Core Audio.
nonisolated public let callAudioBundleID = "com.apple.avconferenced"

nonisolated public struct CallAudioProcess: Sendable, Equatable {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?
    public let isRunningInput: Bool
    public let isRunningOutput: Bool

    public var isActive: Bool { isRunningInput || isRunningOutput }
}

nonisolated public enum CallState: Sendable, Equatable {
    case idle
    case active(CallAudioProcess)

    public var process: CallAudioProcess? {
        if case .active(let p) = self { return p }
        return nil
    }
}

/// Watches the audio daemon and reports when a call starts and stops, so a tap
/// is only alive while there is something to capture.
///
/// Core Audio posts a notification when the process list changes or a process
/// starts/stops IO, so this listens rather than polls. A slow poll remains as a
/// backstop because the IO-state notification is not guaranteed for every
/// transition.
nonisolated public final class CallMonitor: @unchecked Sendable {
    public let targetBundleID: String
    private let queue = DispatchQueue(label: "call-audio-bridge.monitor")
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var watchedProcess: AudioObjectID?
    private var processListener: AudioObjectPropertyListenerBlock?
    private var pollTimer: DispatchSourceTimer?
    private var state: CallState = .idle

    /// Called on an internal queue whenever the call state changes.
    public var onChange: (@Sendable (CallState) -> Void)?

    public init(targetBundleID: String = callAudioBundleID) {
        self.targetBundleID = targetBundleID
    }

    public func start() {
        queue.async { [weak self] in
            self?.installProcessListListener()
            self?.installPollBackstop()
            self?.reevaluate()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pollTimer?.cancel()
            self.pollTimer = nil
            self.removeIOListener()
            if let block = self.processListener {
                var addr = AudioObject.address(kAudioHardwarePropertyProcessObjectList)
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &addr, self.queue, block
                )
                self.processListener = nil
            }
        }
    }

    public var currentState: CallState {
        queue.sync { state }
    }

    // MARK: - listeners

    private func installProcessListListener() {
        var addr = AudioObject.address(kAudioHardwarePropertyProcessObjectList)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.reevaluate()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, queue, block
        )
        if status == noErr { processListener = block }
    }

    /// The IO-state notification is per-process, so it has to be re-attached
    /// whenever the daemon's object id changes (it does across reboots).
    private func installIOListener(for objectID: AudioObjectID) {
        removeIOListener()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.reevaluate()
        }
        var runningAddr = AudioObject.address(kAudioProcessPropertyIsRunning)
        var outputAddr = AudioObject.address(kAudioProcessPropertyIsRunningOutput)
        let a = AudioObjectAddPropertyListenerBlock(objectID, &runningAddr, queue, block)
        let b = AudioObjectAddPropertyListenerBlock(objectID, &outputAddr, queue, block)
        if a == noErr || b == noErr {
            listenerBlock = block
            watchedProcess = objectID
        }
    }

    private func removeIOListener() {
        guard let block = listenerBlock, let objectID = watchedProcess else { return }
        var runningAddr = AudioObject.address(kAudioProcessPropertyIsRunning)
        var outputAddr = AudioObject.address(kAudioProcessPropertyIsRunningOutput)
        AudioObjectRemovePropertyListenerBlock(objectID, &runningAddr, queue, block)
        AudioObjectRemovePropertyListenerBlock(objectID, &outputAddr, queue, block)
        listenerBlock = nil
        watchedProcess = nil
    }

    /// Notifications can be missed; a 2s poll bounds how long that costs us.
    private func installPollBackstop() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + 2,
            repeating: 2,
            leeway: .milliseconds(200)
        )
        timer.setEventHandler { [weak self] in self?.reevaluate() }
        timer.resume()
        pollTimer = timer
    }

    // MARK: - state

    private func reevaluate() {
        let found = Self.findAudioProcess(bundleID: targetBundleID)

        if let found, found.objectID != watchedProcess {
            installIOListener(for: found.objectID)
        }

        let newState: CallState
        if let found, found.isActive {
            newState = .active(found)
        } else {
            newState = .idle
        }

        guard newState != state else { return }
        state = newState
        switch newState {
        case .active(let process):
            BridgeLog.call.notice(
                "call active: pid=\(process.pid, privacy: .public) input=\(process.isRunningInput, privacy: .public) output=\(process.isRunningOutput, privacy: .public)"
            )
        case .idle:
            BridgeLog.call.notice(
                "call idle (daemon \(found == nil ? "absent" : "present", privacy: .public))"
            )
        }
        onChange?(newState)
    }

    /// Resolved by bundle id, never by a cached pid: the daemon is restarted by
    /// launchd and its pid changes.
    public static func findCallAudioProcess() -> CallAudioProcess? {
        findAudioProcess(bundleID: callAudioBundleID)
    }

    /// Prefer an actively-rendering object when an app has several audio
    /// process objects, but retain an idle one so listeners are attached before
    /// playback starts.
    public static func findAudioProcess(bundleID: String) -> CallAudioProcess? {
        let ids = AudioObject.objectList(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyProcessObjectList
        )
        var fallback: CallAudioProcess?
        for id in ids {
            guard AudioObject.string(id, kAudioProcessPropertyBundleID) == bundleID
            else { continue }
            let process = CallAudioProcess(
                objectID: id,
                pid: AudioObject.value(id, kAudioProcessPropertyPID, default: pid_t(-1)),
                bundleID: bundleID,
                isRunningInput: AudioObject.value(
                    id, kAudioProcessPropertyIsRunningInput, default: UInt32(0)) == 1,
                isRunningOutput: AudioObject.value(
                    id, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) == 1
            )
            if process.isRunningOutput { return process }
            if fallback == nil { fallback = process }
        }
        return fallback
    }
}
