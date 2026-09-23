import AVFoundation
import Foundation

/// Microphone and selected-app capture have independent lifetimes. All HAL
/// lifecycle work is serialized; a late permission reply cannot reopen Stop.
///
/// The app tap is opened once at start and kept for the whole session: it
/// follows bundle IDs, so it needs neither a running process nor a rebuild
/// when playback pauses. The monitor only reports whether the app is
/// rendering, and widens the tap if a helper with a new bundle ID appears.
nonisolated public final class CallAudioSession: @unchecked Sendable {
    public enum Direction: String, Sendable { case downlink, uplink }
    private let monitor: CallMonitor
    private let sourceBundleID: String
    private let downlink = DownlinkTap()
    private let uplink = UplinkCapture()
    private let control = DispatchQueue(label: "call-audio-bridge.session", qos: .userInitiated)
    private var active = false
    private var generation = 0
    public var capturesUplink = true
    public var capturesDownlink = true
    public var uplinkDevice: AudioInputDevice?
    public var mutesDownlinkSource = false
    public var onStateChange: (@Sendable (CallState) -> Void)?
    public var onDownlink: (@Sendable (CapturedAudio) -> Void)?
    public var onUplink: (@Sendable (CapturedAudio) -> Void)?
    public var onError: (@Sendable (Error) -> Void)?

    public init(sourceBundleID: String = callAudioBundleID) {
        self.sourceBundleID = sourceBundleID
        monitor = CallMonitor(targetBundleID: sourceBundleID)
    }

    public func start() {
        control.async { [weak self] in
            guard let self, !self.active else { return }
            self.active = true
            self.generation &+= 1
            let token = self.generation
            let downlinkHandler = self.onDownlink
            self.downlink.onBuffer = { downlinkHandler?($0) }
            let uplinkHandler = self.onUplink
            self.uplink.onBuffer = { uplinkHandler?($0) }
            if self.capturesDownlink {
                self.monitor.onChange = { [weak self] state in
                    self?.control.async { [weak self] in
                        guard let self, self.active, self.generation == token else { return }
                        self.onStateChange?(state)
                        self.widenTapIfNeeded()
                    }
                }
                self.openTap()
                self.monitor.start()
            }
            guard self.capturesUplink else { return }
            if case .undetermined = AudioCapturePermission.current {
                AudioCapturePermission.request { [weak self] _ in
                    self?.control.async { [weak self] in self?.openMicrophone(token: token) }
                }
            } else { self.openMicrophone(token: token) }
        }
    }

    private func openTap() {
        do {
            try downlink.start(
                bundleIDs: AudioSourceApplication.tapBundleIDs(for: sourceBundleID),
                muteSource: mutesDownlinkSource
            )
        } catch { onError?(error) }
    }

    /// Process restore covers relaunches of known bundle IDs; only a helper
    /// with an ID the tap has never seen needs a new tap.
    private func widenTapIfNeeded() {
        let wanted = AudioSourceApplication.tapBundleIDs(for: sourceBundleID)
        guard !Set(wanted).isSubset(of: Set(downlink.bundleIDs)) else { return }
        downlink.stop()
        openTap()
    }

    private func openMicrophone(token: Int) {
        guard active, generation == token else { return }
        do { try uplink.start(device: uplinkDevice) }
        catch { onError?(error) }
    }

    public func stop() {
        control.sync {
            active = false
            generation &+= 1
            monitor.stop()
            downlink.stop()
            uplink.stop()
        }
    }

    public var currentState: CallState { monitor.currentState }
}
