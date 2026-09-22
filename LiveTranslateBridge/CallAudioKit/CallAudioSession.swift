import AVFoundation
import Foundation

/// Microphone and selected-app capture have independent lifetimes. All HAL
/// lifecycle work is serialized; a late permission reply cannot reopen Stop.
@available(macOS 14.2, *)
nonisolated public final class CallAudioSession: @unchecked Sendable {
    public enum Direction: String, Sendable { case downlink, uplink }
    private let monitor: CallMonitor
    private let downlink = DownlinkTap()
    private let uplink = UplinkCapture()
    private let control = DispatchQueue(label: "call-audio-bridge.session", qos: .userInitiated)
    private var active = false
    private var generation = 0
    private var tappedProcess: AudioObjectID?
    public var capturesUplink = true
    public var capturesDownlink = true
    public var uplinkDevice: AudioInputDevice?
    public var mutesDownlinkSource = false
    public var onStateChange: (@Sendable (CallState) -> Void)?
    public var onDownlink: (@Sendable (DownlinkTap.Buffer) -> Void)?
    public var onUplink: (@Sendable (AVAudioPCMBuffer) -> Void)?
    public var onError: (@Sendable (Error) -> Void)?

    public init(sourceBundleID: String = callAudioBundleID) {
        monitor = CallMonitor(targetBundleID: sourceBundleID)
    }

    public func start() {
        control.async { [weak self] in
            guard let self, !self.active else { return }
            self.active = true
            self.generation &+= 1
            let token = self.generation
            self.monitor.onChange = { [weak self] state in
                self?.control.async { [weak self] in
                    guard let self, self.active, self.generation == token else { return }
                    self.onStateChange?(state)
                    let process = state.process?.objectID
                    guard process != self.tappedProcess else { return }
                    self.downlink.stop()
                    self.tappedProcess = nil
                    if let process {
                        do {
                            try self.downlink.start(processObjectID: process, muteSource: self.mutesDownlinkSource)
                            self.tappedProcess = process
                        } catch { self.onError?(error) }
                    }
                }
            }
            self.downlink.onBuffer = { [weak self] in self?.onDownlink?($0) }
            self.uplink.onBuffer = { [weak self] in self?.onUplink?($0) }
            // Selected-app listening remains available even while microphone
            // permission is awaiting the user's response.
            if self.capturesDownlink { self.monitor.start() }
            guard self.capturesUplink else { return }
            if case .undetermined = AudioCapturePermission.current {
                AudioCapturePermission.request { [weak self] _ in
                    self?.control.async { [weak self] in self?.openMicrophone(token: token) }
                }
            } else { self.openMicrophone(token: token) }
        }
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
            tappedProcess = nil
        }
    }

    public var currentState: CallState { monitor.currentState }
}
