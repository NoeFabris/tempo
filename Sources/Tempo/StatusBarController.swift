import AppKit
import Combine
import ProductiveCore
import SwiftUI

/// Which popup screen shows.
@MainActor
final class Navigator: ObservableObject {
    enum PickerMode: Equatable {
        case start
        /// Pick the service of the entry form (`nil` = new entry, else the id of the edited entry).
        case form(String?)
    }
    enum Screen: Equatable {
        case main
        case picker(PickerMode)
        /// The manual entry form. Its values live in `draft`, so they survive a trip to the picker.
        case add
        /// Edit the entry with this id. The values live in `draft`.
        case edit(String)
        case settings
    }

    struct EntryDraft: Equatable {
        var service: Service?
        var day: Day?
        var time = ""
        var note = ""
        /// The edited entry as it was when the form opened. Only changed fields are sent.
        var original: TimeEntry?
        var originalTime = ""
    }

    @Published var screen: Screen = .main
    @Published var draft = EntryDraft()

    func startAdd(service: Service?, day: Day) {
        draft = EntryDraft(service: service, day: day)
        screen = .add
    }

    func startEdit(_ entry: TimeEntry, liveMinutes: Int) {
        let time = TimeFormat.hm(liveMinutes)
        draft = EntryDraft(service: entry.service, day: entry.day, time: time, note: entry.note,
                           original: entry, originalTime: time)
        screen = .edit(entry.id)
    }
}

/// Two menu bar items next to each other: `[▶]` starts or stops, `[0:45]` opens the popup.
/// Two items (not one item with two click zones) because the click position in a status item
/// is not reliable on all macOS versions.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let store: TimeStore
    private let nav = Navigator()
    // macOS puts a new status item to the left of the earlier ones: create the time first.
    private let timeItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let playItem = NSStatusBar.system.statusItem(withLength: 26)
    private let popover = NSPopover()
    private var cancellables: Set<AnyCancellable> = []
    private var lastRender = ""
    /// A click on the status item first closes a transient popover (on mouse down), then arrives
    /// here (on mouse up). Without this guard, that click would open the popover again.
    private var popoverClosedAt = Date.distantPast

    private static let iconSize = NSSize(width: 20, height: 16)

    init(store: TimeStore) {
        self.store = store
        super.init()

        popover.behavior = .transient
        popover.delegate = self
        popover.animates = false
        popover.contentSize = NSSize(width: 340, height: 520)
        popover.contentViewController = NSHostingController(
            rootView: PopoverRootView().environmentObject(store).environmentObject(nav)
        )

        timeItem.autosaveName = "TempoTime"
        playItem.autosaveName = "TempoPlay"
        if let button = timeItem.button {
            button.target = self
            button.action = #selector(timeClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Tempo: open the timesheet")
        }
        if let button = playItem.button {
            button.target = self
            button.action = #selector(playClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
        }

        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &cancellables)
        render()
    }

    // MARK: Clicks

    @objc private func playClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp || store.phase == .setup {
            togglePopover()
            return
        }
        Task {
            let handled = await store.toggle()
            if !handled { showPopover(.picker(.start)) }
        }
    }

    @objc private func timeClicked(_ sender: NSStatusBarButton) {
        togglePopover()
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if Date().timeIntervalSince(popoverClosedAt) > 0.3 {
            showPopover()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        popoverClosedAt = Date()
        // Opening the popover makes Tempo the active app. An active app without a full-screen window
        // makes macOS show the menu bar over full-screen apps, so give the focus back.
        if NSApp.isActive { NSApp.hide(nil) }
    }

    func showPopover(_ screen: Navigator.Screen = .main) {
        guard let button = timeItem.button else { return }
        nav.screen = screen
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        Task { await store.refresh() }
    }

    // MARK: Drawing

    private func render() {
        let running = store.isRunning
        let text = store.phase == .setup ? "Set up Tempo" : TimeFormat.hm(store.menuBarMinutes)
        let warn = store.isOffline || store.lastError != nil
        let key = "\(running)|\(text)|\(warn)|\(store.phase)"
        guard key != lastRender else { return }
        lastRender = key

        playItem.isVisible = store.phase == .ready
        if let button = playItem.button {
            button.image = Self.icon(running: running)
            button.setAccessibilityLabel(running ? "Stop the timer" : "Start the timer")
            button.toolTip = running
                ? store.runningService.map { "Stop \($0.name) — \($0.context)" }
                : store.lastService.map { "Start \($0.name) — \($0.context)" } ?? "Pick a service to start"
        }
        if let button = timeItem.button {
            let title = NSMutableAttributedString(
                string: text,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)]
            )
            if warn {
                title.append(NSAttributedString(string: " ⚠︎", attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
            button.attributedTitle = title
            button.toolTip = "Open the Tempo timesheet"
        }
    }

    /// A rounded box with the play or stop glyph cut out, like the Harvest menu bar item.
    /// Stopped: a template image (follows the menu bar colour). Running: violet.
    private static func icon(running: Bool) -> NSImage {
        let symbolName = running ? "stop.fill" : "play.fill"
        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        let image = NSImage(size: iconSize, flipped: false) { rect in
            let box = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            (running ? Brand.nsViolet : NSColor.black).setFill()
            box.fill()
            guard let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return true }
            let size = base.size
            let glyphRect = NSRect(x: rect.midX - size.width / 2 + (running ? 0 : 0.5), y: rect.midY - size.height / 2,
                                   width: size.width, height: size.height)
            if running {
                let white = base.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white])) ?? base
                white.draw(in: glyphRect)
            } else {
                base.draw(in: glyphRect, from: .zero, operation: .destinationOut, fraction: 1)
            }
            return true
        }
        image.isTemplate = !running
        return image
    }
}
