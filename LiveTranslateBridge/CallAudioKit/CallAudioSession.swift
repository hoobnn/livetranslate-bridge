import os
import AVFoundation
import Foundation

/// Ties the monitor to the two capture paths: when a call starts both sides
/// come up, when it ends both are torn down. This is the piece that keeps taps
/// from outliving the call that justified them.
@available(macOS 14.2, *)
nonisolated public final class CallAudioSession: @unchecked Sendable {
    public enum Direction: String, Sendable {
        case downlink   // the far end
        case uplink     // our microphone
    }

    private let monitor: CallMonitor
    private let downlink = DownlinkTap()
    private let uplink = UplinkCapture()
    private let lock = NSLock()
    private var running = false

    /// Where capture is opened when no `CallMonitor` callback is doing it for
    /// us. Opening a device means `AVAudioEngine.start()` and, on the tap side,
    /// a round trip to the HAL — hundreds of milliseconds either can take. On
    /// the call-driven path that already happens on the monitor's own queue;
    /// this gives the uplink-only path somewhere equivalent to run, instead of
    /// stalling whichever thread called `start()` (the main actor, in this
    /// app — which is what produced `NSCGSTransactionCreatedDuringCommitError`
    /// and a window frozen for the duration).
    private let captureQueue = DispatchQueue(
        label: "call-audio-bridge.session", qos: .userInitiated
    )

    /// Whether to open the microphone. Subtitling the far end alone does not
    /// need it, and leaving it shut avoids a permission prompt.
    public var capturesUplink: Bool = true

    /// Whether to open the process tap on the call. Capturing our own side
    /// alone does not need it — and, unlike the tap, the microphone does not
    /// depend on a call existing, so with this off the session stops waiting
    /// for one and captures as soon as it starts. See `start()`.
    public var capturesDownlink: Bool = true

    /// Which device our own side is captured from; nil follows the system
    /// default. Naming it matters when the default input has been handed to a
    /// loopback device so the far end can hear the translation — see
    /// `UplinkCapture`.
    public var uplinkDevice: AudioInputDevice?

    /// Mutes the selected app's direct hardware route while the tap is read.
    /// The caller must replay the captured original through its output mixer.
    public var mutesDownlinkSource = false

    public var onStateChange: (@Sendable (CallState) -> Void)?
    public var onDownlink: (@Sendable (DownlinkTap.Buffer) -> Void)?
    public var onUplink: (@Sendable (AVAudioPCMBuffer) -> Void)?
    public var onError: (@Sendable (Error) -> Void)?

    public init(sourceBundleID: String = callAudioBundleID) {
        monitor = CallMonitor(targetBundleID: sourceBundleID)
    }

    public func start() {
        monitor.onChange = { [weak self] state in
            guard let self else { return }
            self.onStateChange?(state)
            switch state {
            case .active(let process):
                self.beginCapture(processObjectID: process.objectID)
            case .idle:
                self.endCapture()
            }
        }

        // Downlink-only subtitling never opens an input device and therefore
        // must not ask for microphone access. When uplink capture is enabled,
        // settle the prompt before monitoring starts so an already-active call
        // cannot race the permission response and fail its first capture.
        guard capturesUplink else {
            startMonitoringOrCapture()
            return
        }

        BridgeLog.tap.notice(
            "microphone permission at session start: \(AudioCapturePermission.rawDescription, privacy: .public)"
        )
        guard case .undetermined = AudioCapturePermission.current else {
            startMonitoringOrCapture()
            return
        }
        AudioCapturePermission.request { [weak self] granted in
            BridgeLog.tap.notice(
                "microphone requestAccess returned \(granted, privacy: .public); status now \(AudioCapturePermission.rawDescription, privacy: .public)"
            )
            self?.startMonitoringOrCapture()
        }
    }

    /// Begins watching for a call, or — when only the microphone is wanted —
    /// captures straight away.
    ///
    /// Only the process tap needs a call: it is a tap *on* the daemon
    /// rendering one. The microphone is an ordinary input device, so a session
    /// that wants nothing else has nothing to wait for, and waiting would make
    /// the feature useless away from a call — which is most of where capturing
    /// our own side alone is worth anything.
    private func startMonitoringOrCapture() {
        guard capturesDownlink else {
            BridgeLog.tap.notice("uplink-only session: capturing without a call")
            captureQueue.async { [weak self] in
                self?.beginCapture(processObjectID: AudioObjectID(kAudioObjectUnknown))
            }
            return
        }
        monitor.start()
    }

    public func stop() {
        monitor.stop()
        endCapture()
    }

    public var currentState: CallState { monitor.currentState }

    private func beginCapture(processObjectID: AudioObjectID) {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }
        running = true

        if capturesDownlink {
            downlink.onBuffer = { [weak self] buffer in self?.onDownlink?(buffer) }
            do {
                try downlink.start(
                    processObjectID: processObjectID,
                    muteSource: mutesDownlinkSource
                )
            } catch {
                // Also logged, not just reported: `onError` only reaches the
                // status line, and a tap that never opened is exactly what the
                // log pane exists to show.
                BridgeLog.tap.error("tap did not start: \("\(error)", privacy: .public)")
                onError?(error)
            }
        }

        guard capturesUplink else { return }
        uplink.onBuffer = { [weak self] buffer in self?.onUplink?(buffer) }
        do {
            try uplink.start(device: uplinkDevice)
        } catch {
            BridgeLog.tap.error("uplink did not start: \("\(error)", privacy: .public)")
            onError?(error)
        }
    }

    private func endCapture() {
        lock.lock()
        defer { lock.unlock() }
        guard running else { return }
        running = false
        downlink.stop()
        uplink.stop()
    }
}
