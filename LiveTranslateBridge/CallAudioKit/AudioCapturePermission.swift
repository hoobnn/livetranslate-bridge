import AVFoundation
import Foundation

/// The permission for opening the microphone through `AVAudioEngine`.
///
/// This is deliberately independent of `DownlinkTap`: a Core Audio process
/// tap captures another process's output and does not open the microphone.
nonisolated public enum AudioCapturePermission {
    public enum State: Sendable {
        case granted
        case denied
        case undetermined
    }

    public static var current: State {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .undetermined
        default: return .denied
        }
    }

    /// The raw status, for the log: `denied` and `restricted` collapse into
    /// one `State` but mean very different things, and only the raw value
    /// says which one a refusal actually was.
    public static var rawDescription: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "authorized"
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }

    /// Asks the system to prompt, and reports the answer asynchronously.
    ///
    /// Never wait on this from a capture path: the prompt is presented on the
    /// main thread, and the capture path runs on the monitor queue holding a
    /// lock the teardown also needs. Blocking there deadlocks the queue and the
    /// call looks like it went idle. The session asks at `start()` instead, so
    /// by the time a call arrives the answer is already settled.
    public static func request(_ completion: @escaping @Sendable (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
    }
}
