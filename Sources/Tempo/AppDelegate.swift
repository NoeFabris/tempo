import AppKit
import ProductiveCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: TimeStore!
    private var statusBar: StatusBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--render-previews"), i + 1 < CommandLine.arguments.count {
            PreviewRenderer.renderAll(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            NSApp.terminate(nil)
            return
        }
        store = TimeStore()
        statusBar = StatusBarController(store: store)
        store.bootstrap()
        if store.phase == .setup {
            // The status item needs a moment to get its window before the popover can attach.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [statusBar] in statusBar?.showPopover() }
        }
    }
}
