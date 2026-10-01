import AppKit
import ProductiveCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: TimeStore!
    private var statusBar: StatusBarController!
    private var idleMonitor: IdleMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--render-previews"), i + 1 < CommandLine.arguments.count {
            PreviewRenderer.renderAll(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            NSApp.terminate(nil)
            return
        }
        installEditMenu()
        store = TimeStore()
        statusBar = StatusBarController(store: store)
        idleMonitor = IdleMonitor(store: store) { [weak self] in self?.statusBar.itemScreenFrame }
        if CommandLine.arguments.contains("--idle-preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [idleMonitor] in idleMonitor?.preview() }
            return
        }
        if CommandLine.arguments.contains("--click-test") {
            // No account load: the Keychain read can wait for the user's approval.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [statusBar] in statusBar?.runClickTest() }
            return
        }
        store.bootstrap()
        if store.phase == .setup {
            // The status item needs a moment to get its window before the popover can attach.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [statusBar] in statusBar?.showPopover() }
        }
    }

    /// A menu bar-only app has no visible menus, but ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z only work through
    /// the key equivalents of an Edit menu. This menu is never shown.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem(title: "Tempo", action: nil, keyEquivalent: ""))
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
}
