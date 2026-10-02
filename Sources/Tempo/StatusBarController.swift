import AppKit
import os
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
        /// The calendar meeting that this new entry logs.
        var event: CalendarEvent?
    }

    @Published var screen: Screen = .main
    @Published var draft = EntryDraft()

    func startAdd(service: Service?, day: Day) {
        draft = EntryDraft(service: service, day: day)
        screen = .add
    }

    /// A new entry for a calendar meeting: its day, length and name, and the service used last time.
    func startAdd(event: CalendarEvent, service: Service?) {
        draft = EntryDraft(service: service, day: Day(event.start), time: event.isAllDay ? "" : TimeFormat.hm(event.minutes),
                           note: event.name, event: event)
        screen = .add
    }

    func startEdit(_ entry: TimeEntry, liveMinutes: Int) {
        let time = TimeFormat.hm(liveMinutes)
        draft = EntryDraft(service: entry.service, day: entry.day, time: time, note: entry.note,
                           original: entry, originalTime: time)
        screen = .edit(entry.id)
    }
}

/// One menu bar item, like Harvest: `[▶ 0:45]`. The ▶ is a real button inside the item, so AppKit
/// decides which part was clicked. (Calculating the click position from the event was wrong on
/// macOS 27, where the menu bar items are hosted by a system process.)
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let store: TimeStore
    private let nav = Navigator()
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let playButton = NSButton()
    private let popover = NSPopover()
    private var cancellables: Set<AnyCancellable> = []
    private var lastRender = ""
    /// A click on the status item first closes a transient popover (on mouse down), then arrives
    /// here (on mouse up). Without this guard, that click would open the popover again.
    private var popoverClosedAt = Date.distantPast
    /// The app that was in front before the popover opened. It gets the focus back when the popover
    /// closes, so a full-screen app stays the active app and macOS hides the menu bar again.
    private var previousApp: NSRunningApplication?
    private let logger = Logger(subsystem: "app.tempo.menubar", category: "menubar")
    private func log(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        if dryRun { NSLog("%@", message) }
    }
    /// `--click-test` only logs clicks; it must not start timers in the user's account.
    private let dryRun = CommandLine.arguments.contains("--click-test")

    private static let iconSize = NSSize(width: 20, height: 16)
    /// Width of the ▶ zone at the left of the item.
    private static let playZone: CGFloat = 24

    init(store: TimeStore, updates: UpdateController) {
        self.store = store
        super.init()

        popover.behavior = .transient
        popover.delegate = self
        popover.animates = false
        popover.contentSize = NSSize(width: 340, height: 520)
        popover.contentViewController = NSHostingController(
            rootView: PopoverRootView().environmentObject(store).environmentObject(nav).environmentObject(updates)
        )

        item.autosaveName = "Tempo"
        if let button = item.button {
            button.target = self
            button.action = #selector(timeClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Tempo: open the timesheet")
            // An empty image of the ▶ width moves the title to the right of the ▶ button.
            button.image = NSImage(size: NSSize(width: Self.playZone, height: 16))
            button.imagePosition = .imageLeft

            playButton.isBordered = false
            playButton.bezelStyle = .regularSquare
            playButton.imagePosition = .imageOnly
            playButton.imageScaling = .scaleNone
            playButton.focusRingType = .none
            playButton.target = self
            playButton.action = #selector(playClicked(_:))
            playButton.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(playButton)
            NSLayoutConstraint.activate([
                playButton.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 2),
                playButton.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                playButton.widthAnchor.constraint(equalToConstant: Self.playZone),
                playButton.heightAnchor.constraint(equalTo: button.heightAnchor),
            ])
        }

        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &cancellables)
        // A start that needs a note (also from the menu bar ▶): the picker asks for it.
        store.$noteRequired
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.popover.isShown { self.nav.screen = .picker(.start) } else { self.showPopover(.picker(.start)) }
            }
            .store(in: &cancellables)
        render()
    }

    // MARK: Clicks

    @objc private func playClicked(_ sender: NSButton) {
        log("click: play (phase \(store.phase))")
        guard !dryRun else { return }
        if store.phase == .setup {
            togglePopover()
            return
        }
        Task {
            let handled = await store.toggle()
            if !handled { showPopover(.picker(.start)) }
        }
    }

    @objc private func timeClicked(_ sender: NSStatusBarButton) {
        // On macOS 27 a click can arrive through the system's menu bar process instead of as a mouse
        // event, so the ▶ subview never sees it. The pointer position on screen is still correct:
        // if it is over the ▶ zone, treat the click as a ▶ click.
        let pointer = NSEvent.mouseLocation
        let frame = sender.window.map { sender.convert(sender.bounds, to: nil).offsetBy(dx: $0.frame.minX, dy: $0.frame.minY) }
        let overPlay = frame.map { !playButton.isHidden && pointer.x < $0.minX + Self.playZone + 4 && pointer.x >= $0.minX - 2 } ?? false
        let eventType = NSApp.currentEvent?.type.rawValue ?? 0
        log("click: item (event \(eventType), pointer x=\(pointer.x), item \(frame.map { "\($0.minX)–\($0.maxX)" } ?? "?"), over play \(overPlay))")
        if overPlay && NSApp.currentEvent?.type != .rightMouseUp {
            playClicked(playButton)
            return
        }
        guard !dryRun else { return }
        togglePopover()
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if Date().timeIntervalSince(popoverClosedAt) > 0.3 {
            showPopover()
        }
    }

    /// `Tempo --click-test`: sends synthetic clicks to both zones and logs which action ran.
    func runClickTest() {
        guard let button = item.button, let window = button.window else {
            log("click-test: no status item window")
            return
        }
        playButton.isHidden = false
        button.imagePosition = .imageLeft
        button.layoutSubtreeIfNeeded()
        log("click-test: window \(window.windowNumber) frame \(window.frame), play frame \(playButton.frame)")
        for (name, x) in [("play", Self.playZone / 2 + 2), ("time", button.bounds.maxX - 8)] {
            let point = button.convert(NSPoint(x: x, y: button.bounds.midY), to: nil)
            log("click-test: sending \(name) at x=\(point.x) (button width \(button.bounds.width))")
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                  clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                    window.sendEvent(event)
                }
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        popoverClosedAt = Date()
        // Opening the popover makes Tempo the active app. An active app without a full-screen window
        // makes macOS show the menu bar over full-screen apps, so give the focus back to the app that
        // had it. `hide(nil)` lets macOS pick the next app, which is not always the full-screen one.
        guard NSApp.isActive else { return }
        if let previousApp, previousApp != .current, !previousApp.isTerminated {
            NSApp.yieldActivation(to: previousApp)
            previousApp.activate()
        } else {
            NSApp.hide(nil)
        }
        previousApp = nil
    }

    var isPopoverShown: Bool { popover.isShown }

    /// The menu bar item's frame in screen coordinates.
    var itemScreenFrame: NSRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    func showPopover(_ screen: Navigator.Screen = .main) {
        guard let button = item.button else { return }
        nav.screen = screen
        if !NSApp.isActive { previousApp = NSWorkspace.shared.frontmostApplication }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // AppKit puts a status item's popover on the status bar layer (25), above the layer of notification
        // banners (21), so banners slid under it. The utility layer (19) is below them, and still above
        // normal windows and floating panels.
        popover.contentViewController?.view.window?.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.utilityWindow)))
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
        guard let button = item.button else { return }

        let ready = store.phase == .ready
        playButton.isHidden = !ready
        button.imagePosition = ready ? .imageLeft : .noImage
        playButton.image = Self.icon(running: running)
        playButton.setAccessibilityLabel(running ? "Stop the timer" : "Start the timer")
        playButton.toolTip = running
            ? store.runningService.map { "Stop \($0.name) — \($0.context)" }
            : store.lastService.map { "Start \($0.name) — \($0.context)" } ?? "Pick a service to start"

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
