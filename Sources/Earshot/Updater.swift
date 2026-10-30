import Foundation
import Observation
import Sparkle

/// Sparkle 2: reads the appcast (SUFeedURL), installs EdDSA-signed zips (SUPublicEDKey) in place.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    private(set) var canCheckForUpdates = false
    private(set) var lastCheck: Date?
    var automaticallyChecksForUpdates: Bool {
        didSet { if updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates { updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates } }
    }
    var automaticallyDownloadsUpdates: Bool {
        didSet { if updater.automaticallyDownloadsUpdates != automaticallyDownloadsUpdates { updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates } }
    }

    /// Off in `swift run` builds: without the app's Info.plist there is no feed or key.
    let isAvailable = Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

    @ObservationIgnored private let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    @ObservationIgnored private var observers: [NSKeyValueObservation] = []
    private var updater: SPUUpdater { controller.updater }

    private init() {
        let updater = controller.updater
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        lastCheck = updater.lastUpdateCheckDate
    }

    func start() {
        guard isAvailable, observers.isEmpty else { return }
        observers = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] u, _ in
                let can = u.canCheckForUpdates
                Task { @MainActor in
                    guard let self else { return }
                    // Back to true: a check just finished.
                    if can, !self.canCheckForUpdates { self.refresh() }
                    self.canCheckForUpdates = can
                }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] u, _ in
                let date = u.lastUpdateCheckDate
                Task { @MainActor in self?.lastCheck = date }
            },
        ]
        controller.startUpdater()
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
    }

    /// KVO on lastUpdateCheckDate isn't reliable, and Sparkle's own "check automatically?" prompt changes the setting:
    /// read both again when the settings show and after each check.
    func refresh() {
        guard isAvailable else { return }
        lastCheck = updater.lastUpdateCheckDate
        if automaticallyChecksForUpdates != updater.automaticallyChecksForUpdates { automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates }
        if automaticallyDownloadsUpdates != updater.automaticallyDownloadsUpdates { automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }
}
