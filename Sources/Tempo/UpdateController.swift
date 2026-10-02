import AppKit
import Combine
import os
import Sparkle

/// Wraps Sparkle for the menu bar app. One instance for the app's lifetime, created by `AppDelegate`.
/// `start()` runs only in a normal run: preview, idle-preview and click-test runs never touch the
/// network or show update alerts. Sparkle reads `SUFeedURL` and `SUPublicEDKey` from Info.plist.
///
/// Automatic updates (on by default, `SUAutomaticallyUpdate`): Sparkle downloads a new version in the
/// background and hands over a block that installs it and relaunches the app. Sparkle itself waits for a
/// quit, which a menu bar app rarely sees, so this controller runs the block at a quiet moment: the popup
/// is closed and `isBusy` is false. The running timer is safe: it runs in Productive, not in the app.
@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    /// False before `start()` and while an update session runs.
    @Published private(set) var canCheckForUpdates = false
    /// True while a scheduled (not user-initiated) update waits for the user's attention. The footer
    /// shows a hint; a click runs `checkForUpdates()`, which brings Sparkle's alert to the front.
    /// Only with automatic installs off: otherwise the update arrives as `readyVersion`.
    @Published private(set) var updateAvailable = false
    /// The version of a downloaded update that waits for a quiet moment to install. The footer shows it.
    @Published private(set) var readyVersion: String?
    /// The two Sparkle settings, mirrored for the Settings screen. Sparkle stores them.
    @Published private(set) var automaticallyChecks = true
    @Published private(set) var automaticallyInstalls = true
    /// `CFBundleShortVersionString`, or "dev" outside an app bundle.
    let version: String

    /// True while a relaunch would lose something: a change on its way to Productive, or the idle question.
    var isBusy: () -> Bool = { false }
    /// True while the popup shows.
    var isPopoverShown: () -> Bool = { false }

    private var controller: SPUStandardUpdaterController!
    private var cancellables: Set<AnyCancellable> = []
    private let logger = Logger(subsystem: "app.tempo.menubar", category: "updates")
    /// Sparkle's block that installs the downloaded update and relaunches the app.
    private var installUpdate: (() -> Void)?
    private var installRequested = false
    private var retry: Timer?

    override init() {
        version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        super.init()
        // startingUpdater: false has no side effects, so previews can create this freely.
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] can in self?.canCheckForUpdates = can }
            .store(in: &cancellables)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .sink { [weak self] on in self?.automaticallyChecks = on }
            .store(in: &cancellables)
        updater.publisher(for: \.automaticallyDownloadsUpdates)
            .sink { [weak self] on in self?.automaticallyInstalls = on }
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

    func setAutomaticallyChecks(_ on: Bool) {
        controller.updater.automaticallyChecksForUpdates = on
    }

    func setAutomaticallyInstalls(_ on: Bool) {
        controller.updater.automaticallyDownloadsUpdates = on
    }

    /// The footer button: installs the downloaded update now, or as soon as no change waits for Productive.
    func installNow() {
        installRequested = true
        installWhenQuiet()
    }

    /// Runs Sparkle's install block when nothing would be lost; otherwise tries again every 30 s.
    private func installWhenQuiet() {
        guard let installUpdate else { return }
        let allowed = installRequested || (automaticallyInstalls && !isPopoverShown())
        guard allowed && !isBusy() else {
            if retry == nil {
                logger.notice("update \(self.readyVersion ?? "?", privacy: .public) waits for a quiet moment")
                retry = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.installWhenQuiet() }
                }
            }
            return
        }
        retry?.invalidate()
        retry = nil
        logger.notice("installing update \(self.readyVersion ?? "?", privacy: .public) and relaunching")
        installUpdate()
    }

    // MARK: - SPUUpdaterDelegate (called by Sparkle on the main thread)

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        MainActor.assumeIsolated {
            readyVersion = version
            installUpdate = immediateInstallHandler
            logger.notice("update \(version, privacy: .public) downloaded")
            // Not inside this callback: Sparkle expects the answer below before the block runs.
            DispatchQueue.main.async { [weak self] in self?.installWhenQuiet() }
        }
        return true // This controller installs it. Sparkle still installs it on quit.
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
