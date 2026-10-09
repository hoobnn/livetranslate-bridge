import Combine
import Foundation
import Observation
import Sparkle

/// In-app updates through Sparkle.
///
/// The feed, the public key that update archives must be signed with, and the
/// default for automatic checks all live in Info.plist (`SUFeedURL`,
/// `SUPublicEDKey`, `SUEnableAutomaticChecks`). Sparkle shows its own windows
/// for what it finds; this type only exposes what the menu bar and Settings
/// need: whether a check can start now, and the automatic-check preference.
@MainActor
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    /// False while a check or an update is already in progress — the menu
    /// item and the Settings button grey out instead of queueing a second one.
    private(set) var canCheckForUpdates = false

    /// Sparkle keeps this in user defaults itself; the copy here is what
    /// SwiftUI observes.
    var automaticallyChecksForUpdates: Bool {
        didSet {
            guard automaticallyChecksForUpdates != oldValue else { return }
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    /// The running version, as Sparkle compares it against the feed.
    let currentVersion: String

    private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: AnyCancellable?

    private init() {
        // A test run hosts the app; it must not go looking for updates.
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        controller = SPUStandardUpdaterController(
            startingUpdater: !isTesting, updaterDelegate: nil, userDriverDelegate: nil
        )
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "?"
        observation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
    }

    /// "Check for Updates…": always reports back, even when already current.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
