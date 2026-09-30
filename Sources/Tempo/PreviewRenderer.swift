import AppKit
import ProductiveCore
import SwiftUI

/// `Tempo --render-previews <dir>` draws each popup screen with sample data to PNG files.
/// Used to check the design without a Productive account.
@MainActor
enum PreviewRenderer {
    static func renderAll(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "tempo-preview")!
        defaults.removePersistentDomain(forName: "tempo-preview")
        let settings = SettingsStore(defaults: defaults)
        let api = SampleAPI()
        settings.lastService = api.services[0]
        settings.favourites = [Favourite(service: api.services[0]), Favourite(service: api.services[2]),
                               Favourite(service: Service(id: "1", name: "CRO Strategy", budgetName: "Budget (Aug 2026)",
                                                          projectName: "[NWR] NWR - Full service experimentation",
                                                          clientName: "Northwind Retail Limited"))]
        let store = TimeStore(settings: settings, tokenStore: SampleTokens(), makeAPI: { _ in api })
        let group = DispatchGroup()
        group.enter()
        Task {
            await store.connect(token: "sample", organizationID: "1")
            let stopped: [(String, Navigator.Screen)] = [("main-stopped", .main)]
            for scheme in [ColorScheme.dark, .light] {
                for (name, screen) in stopped { render(store, screen, scheme, dir, name) }
            }
            await store.start(api.services[0])
            let editEntry = store.entries.first { $0.service.id == api.services[1].id && !$0.isLocked }!
            let running: [(String, Navigator.Screen)] = [
                ("main-running", .main), ("picker", .picker(.start)), ("edit", .edit(editEntry.id)), ("settings", .settings),
            ]
            for scheme in [ColorScheme.dark, .light] {
                for (name, screen) in running {
                    render(store, screen, scheme, dir, name) { nav in
                        if case .edit = screen { nav.startEdit(editEntry, liveMinutes: editEntry.minutes) }
                    }
                }
            }
            store.signOut()
            for scheme in [ColorScheme.dark, .light] { render(store, .main, scheme, dir, "setup") }
            group.leave()
        }
        while group.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    private static func render(_ store: TimeStore, _ screen: Navigator.Screen, _ scheme: ColorScheme, _ dir: URL, _ name: String,
                               prepare: (Navigator) -> Void = { _ in }) {
        let nav = Navigator()
        prepare(nav)
        nav.screen = screen
        let view = PopoverRootView().environmentObject(store).environmentObject(nav).environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 520)
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = host.appearance
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        let file = dir.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png")
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
    }
}

private final class SampleTokens: TokenStoring, @unchecked Sendable {
    func read() -> String? { "sample" }
    func write(_ token: String) -> Bool { true }
}

private final class SampleAPI: ProductiveAPI, @unchecked Sendable {
    let services = [
        Service(id: "9001", name: "CRO Development", budgetName: "[NWR] NWR - Full service experimentation - Budget (Sep 2026)",
                projectName: "[NWR] NWR - Full service experimentation", clientName: "Northwind Retail Limited"),
        Service(id: "9002", name: "Internal meetings", budgetName: "Internal", projectName: "Internal", clientName: "Acme Agency Ltd"),
        Service(id: "9003", name: "UX Research", budgetName: "Retainer 2026", projectName: "[FAB] Experimentation", clientName: "Fabrikam Finance"),
        Service(id: "9004", name: "Analytics", budgetName: "Retainer 2026", projectName: "[FAB] Experimentation", clientName: "Fabrikam Finance"),
    ]
    lazy var entries: [TimeEntry] = {
        let week = Week.days(containing: Day(Date()), firstWeekday: 2)
        var list: [TimeEntry] = []
        var id = 100
        for (i, day) in week.enumerated() where day < Day(Date()) {
            for (s, m, n) in [(0, 240 + i * 15, "Build PDP test"), (1, 60, "Stand-up"), (2, 150, "Survey analysis")] {
                id += 1
                list.append(TimeEntry(id: String(id), day: day, minutes: m, note: n, service: services[s], isLocked: i == 0))
            }
        }
        list.append(TimeEntry(id: "900", day: Day(Date()), minutes: 105, note: "", service: services[0],
                              jira: JiraLink(key: "WT-558", summary: "WT E97 Checkout Test 1 — Shorter Form",
                                             url: URL(string: "https://example.atlassian.net/browse/WT-558"))))
        list.append(TimeEntry(id: "901", day: Day(Date()), minutes: 30, note: "Client call", service: services[1]))
        return list
    }()
    var timer: RunningTimer?

    func me() async throws -> Person { Person(id: "77", name: "Noe Fabris") }
    func recentTimers(personID: String) async throws -> [RunningTimer] { timer.map { [$0] } ?? [] }
    func timeEntries(personID: String, from: Day, to: Day) async throws -> [TimeEntry] {
        entries.filter { $0.day >= from && $0.day <= to }
    }
    func trackableServices(personID: String) async throws -> [Service] { services }
    func createTimeEntry(personID: String, serviceID: String, day: Day, minutes: Int, note: String) async throws -> TimeEntry {
        let e = TimeEntry(id: UUID().uuidString, day: day, minutes: minutes, note: note, service: services.first { $0.id == serviceID }!)
        entries.append(e)
        return e
    }
    func updateTimeEntry(id: String, changes: EntryChanges) async throws -> TimeEntry {
        let i = entries.firstIndex { $0.id == id }!
        if let note = changes.note { entries[i].note = note }
        return entries[i]
    }
    func deleteTimeEntry(id: String) async throws {}
    func startTimer(timeEntryID: String) async throws -> RunningTimer {
        let t = RunningTimer(id: "t1", startedAt: Date().addingTimeInterval(-(24 * 60 + 5)), timeEntryID: timeEntryID)
        timer = t
        return t
    }
    func stopTimer(id: String) async throws -> RunningTimer { timer! }
    func calendarEvents(personID: String, day: Day) async throws -> [CalendarEvent] {
        let base = Calendar.current.startOfDay(for: day.date())
        func at(_ h: Int, _ m: Int) -> Date { base.addingTimeInterval(TimeInterval(h * 3600 + m * 60)) }
        return [
            CalendarEvent(id: "e1", name: "Daily stand-up", start: at(9, 30), end: at(10, 0), seriesID: "daily"),
            CalendarEvent(id: "e2", name: "Northwind Retail — test review", start: at(14, 0), end: at(15, 0), organizer: "Client"),
            CalendarEvent(id: "e3", name: "Declined sync", start: at(16, 0), end: at(16, 30), responseStatus: "declined"),
        ]
    }
}
