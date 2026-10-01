import AppKit
import Combine
import os
import Sparkle

/// Wraps Sparkle for the menu bar app. One instance for the app's lifetime, created by `AppDelegate`.
/// `start()` runs only in a normal run: preview, idle-preview and click-test runs never touch the
/// network or show update alerts. Sparkle reads `SUFeedURL` and `SUPublicEDKey` from Info.plist.
@MainActor
final class UpdateController: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    /// False before `start()` and while an update session runs.
    @Published private(set) var canCheckForUpdates = false
    /// True while a scheduled (not user-initiated) update waits for the user's attention. The footer
    /// shows a hint; a click runs `checkForUpdates()`, which brings Sparkle's alert to the front.
    @Published private(set) var updateAvailable = false
    /// `CFBundleShortVersionString`, or "dev" outside an app bundle.
    let version: String

    private var controller: SPUStandardUpdaterController!
    private var cancellables: Set<AnyCancellable> = []
    private let logger = Logger(subsystem: "app.tempo.menubar", category: "updates")

    override init() {
        version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        super.init()
        // startingUpdater: false has no side effects, so previews can create this freely.
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] can in self?.canCheckForUpdates = can }
            .store(in: &cancellables)
    }

    /// Starts the scheduled checks (once a day, `SUScheduledCheckInterval`).
    func start() {
        do {
            try controller.updater.start()
        } catch {
            logger.error("Sparkle did not start: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A user-initiated check. Sparkle shows the result in front of other apps.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    // MARK: - SPUStandardUserDriverDelegate (called by Sparkle on the main thread)

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                                          andInImmediateFocus immediateFocus: Bool) -> Bool {
        // Right after launch Sparkle may show the alert itself. Later the footer hint takes over.
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        let scheduled = !state.userInitiated
        MainActor.assumeIsolated { updateAvailable = scheduled }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { updateAvailable = false }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { updateAvailable = false }
    }
}
