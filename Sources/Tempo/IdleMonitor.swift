import AppKit
import Combine
import CoreGraphics
import ProductiveCore
import SwiftUI

/// Watches for idle time while a timer runs, like Harvest. After `store.idleMinutes` without keyboard
/// or mouse use (or a sleep), it waits until the user is back and then asks what to do.
@MainActor
final class IdleMonitor {
    private let store: TimeStore
    private var ticker: Timer?
    /// When the idle time started (the last input before the idle period).
    private var idleSince: Date?
    private var panel: NSPanel?
    private var cancellables: Set<AnyCancellable> = []

    init(store: TimeStore) {
        self.store = store
        ticker = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        let center = NSWorkspace.shared.notificationCenter
        // A sleep or a locked screen is idle time too: mark its start before the Mac sleeps.
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            center.publisher(for: name)
                .sink { [weak self] _ in self?.markIdleStartIfRunning(at: Date()) }
                .store(in: &cancellables)
        }
        // Close the question when the timer stops somewhere else.
        store.$timer
            .receive(on: RunLoop.main)
            .sink { [weak self] timer in if timer == nil { self?.dismiss() } }
            .store(in: &cancellables)
    }

    /// Seconds since the last keyboard, mouse or trackpad event. Needs no permission.
    private static var secondsSinceInput: TimeInterval {
        let anyInput = unsafeBitCast(UInt32.max, to: CGEventType.self) // kCGAnyInputEventType
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    private func markIdleStartIfRunning(at date: Date) {
        guard store.idleDetection, store.isRunning, idleSince == nil else { return }
        idleSince = date.addingTimeInterval(-min(Self.secondsSinceInput, 60))
    }

    private func check() {
        guard store.idleDetection, let timer = store.timer else {
            idleSince = nil
            return
        }
        let idle = Self.secondsSinceInput
        let limit = TimeInterval(store.idleMinutes * 60)
        if idle >= limit {
            if idleSince == nil { idleSince = Date().addingTimeInterval(-idle) }
        } else if let since = idleSince, idle < 30 {
            // The user is back.
            idleSince = nil
            let start = max(since, timer.startedAt)
            guard Date().timeIntervalSince(start) >= limit else { return }
            ask(idleStart: start)
        }
    }

    // MARK: The question

    private func ask(idleStart: Date) {
        let view = IdlePromptView(idleStart: idleStart) { [weak self] choice in
            self?.dismiss()
            guard let self else { return }
            Task {
                switch choice {
                case .keep: break
                case .removeAndContinue: await self.store.removeIdleTime(since: idleStart, keepRunning: true)
                case .removeAndStop: await self.store.removeIdleTime(since: idleStart, keepRunning: false)
                }
            }
        }
        .environmentObject(store)

        dismiss()
        // Non-activating: a click does not make Tempo the active app, so full-screen apps keep the
        // menu bar hidden. Shown on every Space, including full-screen ones.
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 230),
                            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: view)
        panel.setContentSize(panel.contentView!.fittingSize)
        panel.center()
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

struct IdlePromptView: View {
    enum Choice { case keep, removeAndContinue, removeAndStop }

    @EnvironmentObject var store: TimeStore
    let idleStart: Date
    let choose: (Choice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let minutes = max(0, Int(store.now.timeIntervalSince(idleStart)) / 60)
            BrandHeading(bold: "You were idle", italic: "for " + (minutes < 60 ? "\(minutes) min" : TimeFormat.hm(minutes)), size: 17)
            Text("Since \(idleStart.formatted(date: .omitted, time: .shortened)). The timer kept running.")
                .font(Brand.font(12)).foregroundStyle(Brand.secondary)
            if let entry = store.runningEntry {
                EntryLabels(entry: entry)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
            }
            VStack(spacing: 6) {
                Button("Remove idle time and continue") { choose(.removeAndContinue) }
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(maxWidth: .infinity)
                    .keyboardShortcut(.defaultAction)
                HStack(spacing: 6) {
                    Button("Remove and stop") { choose(.removeAndStop) }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("Keep idle time") { choose(.keep) }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(20)
        .padding(.top, 8)
        .frame(width: 340)
        .background(Brand.background)
        .foregroundStyle(Brand.text)
    }
}
