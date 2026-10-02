import XCTest
@testable import ProductiveCore

final class MockAPI: ProductiveAPI, @unchecked Sendable {
    var person = Person(id: "77", name: "Noe Fabris")
    var entries: [TimeEntry] = []
    var timers: [RunningTimer] = []
    var services: [Service] = []
    var failure: ProductiveError?
    var calls: [String] = []
    /// Seconds that `createTimeEntry` waits, to look at the store while a request runs.
    var createDelay: TimeInterval = 0
    private var nextID = 1000

    private func check(_ call: String) throws {
        calls.append(call)
        if let failure { throw failure }
    }

    private func newID() -> String { nextID += 1; return String(nextID) }

    func me() async throws -> Person { try check("me"); return person }
    func recentTimers(personID: String) async throws -> [RunningTimer] { try check("timers"); return timers }
    func timeEntries(personID: String, from: Day, to: Day) async throws -> [TimeEntry] {
        try check("entries")
        return entries.filter { $0.day >= from && $0.day <= to }
    }
    func trackableServices(personID: String) async throws -> [Service] { try check("services"); return services }

    func createTimeEntry(personID: String, serviceID: String, day: Day, minutes: Int, note: String) async throws -> TimeEntry {
        try check("create \(serviceID) \(minutes)")
        if createDelay > 0 { try await Task.sleep(nanoseconds: UInt64(createDelay * 1e9)) }
        let service = services.first { $0.id == serviceID } ?? Service(id: serviceID, name: "S")
        let e = TimeEntry(id: newID(), day: day, minutes: minutes, note: note, service: service)
        entries.append(e)
        return e
    }

    func updateTimeEntry(id: String, changes: EntryChanges) async throws -> TimeEntry {
        try check("update \(id) \(changes.minutes.map(String.init) ?? "-")")
        guard let i = entries.firstIndex(where: { $0.id == id }) else { throw ProductiveError.http(status: 404, message: "Not found") }
        if let minutes = changes.minutes { entries[i].minutes = minutes }
        if let note = changes.note { entries[i].note = note }
        if let day = changes.day { entries[i].day = day }
        if let serviceID = changes.serviceID { entries[i].service = services.first { $0.id == serviceID } ?? Service(id: serviceID, name: "S") }
        return entries[i]
    }

    func deleteTimeEntry(id: String) async throws {
        try check("delete \(id)")
        entries.removeAll { $0.id == id }
    }

    func startTimer(timeEntryID: String) async throws -> RunningTimer {
        try check("start \(timeEntryID)")
        let t = RunningTimer(id: newID(), startedAt: Date(), timeEntryID: timeEntryID)
        timers.insert(t, at: 0)
        return t
    }

    var events: [Day: [CalendarEvent]] = [:]
    func calendarEvents(personID: String, day: Day) async throws -> [CalendarEvent] {
        try check("calendar \(day.iso)")
        return events[day] ?? []
    }

    func stopTimer(id: String) async throws -> RunningTimer {
        try check("stop \(id)")
        let i = timers.firstIndex { $0.id == id }!
        let t = timers[i]
        let elapsed = Int(Date().timeIntervalSince(t.startedAt)) / 60
        if let e = entries.firstIndex(where: { $0.id == t.timeEntryID }) { entries[e].minutes += elapsed }
        timers[i] = RunningTimer(id: t.id, startedAt: t.startedAt, stoppedAt: Date(), timeEntryID: t.timeEntryID)
        return timers[i]
    }
}

final class MemoryTokenStore: TokenStoring, @unchecked Sendable {
    var token: String?
    var reads = 0
    init(_ token: String? = nil) { self.token = token }
    func read() -> String? { reads += 1; return token }
    func write(_ token: String) -> Bool { self.token = token.isEmpty ? nil : token; return true }
}

@MainActor
final class TimeStoreTests: XCTestCase {
    var api: MockAPI!
    var settings: SettingsStore!
    let cro = Service(id: "9001", name: "CRO Development", clientName: "Northwind Retail")

    override func setUp() async throws {
        api = MockAPI()
        api.services = [cro]
        let defaults = UserDefaults(suiteName: "tempo-tests-\(UUID().uuidString)")!
        settings = SettingsStore(defaults: defaults)
    }

    func connectedStore() async -> TimeStore {
        let store = TimeStore(settings: settings, tokenStore: MemoryTokenStore(), makeAPI: { [api] _ in api! })
        let person = await store.connect(token: " tok ", organizationID: "555")
        XCTAssertEqual(person?.name, "Noe Fabris")
        return store
    }

    func testTokenIsReadOncePerLaunch() async {
        settings.organizationID = "555"
        settings.person = Person(id: "77", name: "Noe Fabris")
        let tokens = MemoryTokenStore("tok")
        let store = TimeStore(settings: settings, tokenStore: tokens, makeAPI: { [api] _ in api! })
        store.bootstrap()
        XCTAssertEqual(tokens.reads, 1)
        XCTAssertTrue(store.hasStoredToken)
        // Settings: "Test connection" with the field left empty keeps the saved token.
        let person = await store.connect(token: "", organizationID: "555")
        XCTAssertEqual(person?.id, "77")
        XCTAssertEqual(tokens.reads, 1, "no second token read")
        XCTAssertEqual(tokens.token, "tok")
    }

    func testStartWithNoteMakesEntryWithThatNote() async {
        api.entries = [TimeEntry(id: "501", day: Day(Date()), minutes: 30, note: "", service: cro)]
        let store = await connectedStore()
        await store.start(cro, note: "E97 QA")
        XCTAssertTrue(api.calls.contains("create 9001 0"), "a noted start does not join the entry without a note")
        XCTAssertEqual(api.entries.last?.note, "E97 QA")
        XCTAssertEqual(store.runningEntry?.note, "E97 QA")
    }

    func testWeekendsHiddenByDefault() async {
        let store = await connectedStore()
        XCTAssertFalse(store.showWeekends)
        XCTAssertEqual(store.visibleWeekDays.count, 5)
        XCTAssertFalse(store.visibleWeekDays.contains { Calendar.current.isDateInWeekend($0.date()) })
        store.setShowWeekends(true)
        XCTAssertEqual(store.visibleWeekDays.count, 7)
        XCTAssertTrue(settings.showWeekends)
    }

    func testSetupPhaseWithoutToken() {
        let store = TimeStore(settings: settings, tokenStore: MemoryTokenStore(), makeAPI: { [api] _ in api! })
        store.bootstrap()
        XCTAssertEqual(store.phase, .setup)
    }

    func testConnectStoresTrimmedTokenAndLoads() async {
        let tokens = MemoryTokenStore()
        let store = TimeStore(settings: settings, tokenStore: tokens, makeAPI: { [api] _ in api! })
        await store.connect(token: " tok \n", organizationID: " 555 ")
        XCTAssertEqual(tokens.token, "tok")
        XCTAssertEqual(settings.organizationID, "555")
        XCTAssertEqual(store.phase, .ready)
        XCTAssertEqual(store.services, [cro])
    }

    func testConnectFailureKeepsSetup() async {
        api.failure = .unauthorized
        let store = TimeStore(settings: settings, tokenStore: MemoryTokenStore(), makeAPI: { [api] _ in api! })
        let person = await store.connect(token: "bad", organizationID: "555")
        XCTAssertNil(person)
        XCTAssertEqual(store.phase, .setup)
        XCTAssertNotNil(store.lastError)
    }

    func testStartCreatesEntryThenTimer() async {
        let store = await connectedStore()
        await store.start(cro)
        XCTAssertTrue(store.isRunning)
        XCTAssertEqual(store.runningService?.id, cro.id)
        XCTAssertTrue(api.calls.contains("create 9001 0"))
        XCTAssertEqual(settings.lastService, cro)
    }

    func testStartContinuesTodaysEntry() async {
        api.entries = [TimeEntry(id: "501", day: Day(Date()), minutes: 45, note: "", service: cro)]
        let store = await connectedStore()
        await store.start(cro)
        XCTAssertFalse(api.calls.contains { $0.hasPrefix("create") })
        XCTAssertTrue(api.calls.contains("start 501"))
        XCTAssertEqual(store.menuBarMinutes, 45, "base minutes plus a session of 0 minutes")
    }

    func testToggleResumesTheLastEntryNotAnotherOnTheSameService() async {
        let today = Day(Date())
        api.entries = [TimeEntry(id: "501", day: today, minutes: 30, note: "E97", service: cro),
                       TimeEntry(id: "502", day: today, minutes: 20, note: "E95", service: cro)]
        let store = await connectedStore()
        await store.start(cro, continuing: store.entries[1])
        await store.stop()
        XCTAssertEqual(store.resumableEntry?.id, "502")
        api.calls = []
        await store.toggle()
        XCTAssertEqual(api.calls.filter { $0.hasPrefix("start") }, ["start 502"])
        XCTAssertFalse(api.calls.contains { $0.hasPrefix("create") })
    }

    func testToggleAfterMidnightStartsNewEntryWithSameNote() async {
        var clock = Calendar.current.date(bySettingHour: 23, minute: 50, second: 0, of: Date())!
        api.entries = [TimeEntry(id: "501", day: Day(clock), minutes: 30, note: "E97", service: cro)]
        let store = TimeStore(settings: settings, tokenStore: MemoryTokenStore(), makeAPI: { [api] _ in api! }, clock: { clock })
        await store.connect(token: "t", organizationID: "1")
        await store.start(cro, continuing: store.entries[0])
        await store.stop()
        clock = clock.addingTimeInterval(20 * 60) // 00:10 the next day
        api.calls = []
        await store.toggle()
        XCTAssertTrue(api.calls.contains("create 9001 0"))
        XCTAssertEqual(api.entries.last?.note, "E97")
        XCTAssertEqual(api.entries.last?.day, Day(clock))
    }

    func testTimerStartedElsewhereBecomesResumable() async {
        let entry = TimeEntry(id: "501", day: Day(Date()), minutes: 30, note: "E97", service: cro)
        api.entries = [entry]
        api.timers = [RunningTimer(id: "7001", startedAt: Date(), timeEntryID: "501")]
        let store = await connectedStore()
        XCTAssertEqual(settings.lastEntry?.entryID, "501")
        XCTAssertEqual(settings.lastService, cro)
    }

    func testChipStartDoesNotJoinAnEntryWithANote() async {
        api.entries = [TimeEntry(id: "501", day: Day(Date()), minutes: 30, note: "E97", service: cro)]
        let store = await connectedStore()
        await store.start(cro)
        XCTAssertTrue(api.calls.contains("create 9001 0"), "E97 work stays separate")
    }

    func testShortClientName() {
        XCTAssertEqual(Service(id: "1", name: "S", clientName: "Wingtip Online Ltd").shortClientName, "Wingtip Online")
        XCTAssertEqual(Service(id: "1", name: "S", clientName: "Northwind Retail Limited").shortClientName, "Northwind Retail")
        XCTAssertEqual(Service(id: "1", name: "S", clientName: "Tailspin Sports Online.com B.V").shortClientName, "Tailspin Sports Online.com")
        XCTAssertEqual(Service(id: "1", name: "S", clientName: "Acme, Inc.").shortClientName, "Acme")
    }

    func testLockedEntryIsNotContinued() async {
        api.entries = [TimeEntry(id: "501", day: Day(Date()), minutes: 45, note: "", service: cro, isLocked: true)]
        let store = await connectedStore()
        await store.start(cro)
        XCTAssertTrue(api.calls.contains("create 9001 0"))
    }

    func testToggleWithoutLastServiceAsksForPicker() async {
        let store = await connectedStore()
        let handled = await store.toggle()
        XCTAssertFalse(handled)
        XCTAssertFalse(store.isRunning)
    }

    func testToggleStartsLastThenStops() async {
        settings.lastService = cro
        let store = await connectedStore()
        await store.toggle()
        XCTAssertTrue(store.isRunning)
        await store.toggle()
        XCTAssertFalse(store.isRunning)
        XCTAssertTrue(api.calls.contains { $0.hasPrefix("stop") })
    }

    func testRefreshPicksUpTimerStartedElsewhere() async {
        let entry = TimeEntry(id: "501", day: Day(Date()), minutes: 30, note: "", service: cro)
        api.entries = [entry]
        api.timers = [RunningTimer(id: "7001", startedAt: Date().addingTimeInterval(-600), timeEntryID: "501")]
        let store = await connectedStore()
        XCTAssertTrue(store.isRunning)
        XCTAssertEqual(store.liveMinutes(entry), 40)
    }

    func testOfflineStartAndStopBecomesOneLoggedBlock() async {
        var clock = Date()
        let store = TimeStore(settings: settings, tokenStore: MemoryTokenStore(), makeAPI: { [api] _ in api! }, clock: { clock })
        await store.connect(token: "tok", organizationID: "555")
        api.failure = .offline
        await store.start(cro)
        XCTAssertTrue(store.isRunning, "the UI shows the timer while offline")
        XCTAssertTrue(store.isOffline)
        clock = clock.addingTimeInterval(25 * 60)
        await store.stop()
        XCTAssertFalse(store.isRunning)
        guard case .log(_, let service, let day, let entryID, _, let minutes, _)? = store.pending.first, store.pending.count == 1 else {
            return XCTFail("expected one .log, got \(store.pending)")
        }
        XCTAssertEqual(service, cro)
        XCTAssertEqual(day, Day(clock))
        XCTAssertNil(entryID)
        XCTAssertEqual(minutes, 25)

        XCTAssertTrue(store.hasPendingWork, "the offline block must not be lost by a relaunch")

        api.failure = nil
        await store.refresh()
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertFalse(store.isOffline)
        XCTAssertTrue(api.calls.contains("create 9001 25"))
        XCTAssertFalse(store.hasPendingWork)
    }

    func testRefusedOfflineChangeIsDroppedAndReported() async {
        var clock = Date()
        api.entries = [TimeEntry(id: "501", day: Day(clock), minutes: 30, note: "", service: cro)]
        api.timers = [RunningTimer(id: "7001", startedAt: clock.addingTimeInterval(-10 * 60), timeEntryID: "501")]
        let store = TimeStore(settings: settings, tokenStore: MemoryTokenStore(), makeAPI: { [api] _ in api! }, clock: { clock })
        await store.connect(token: "tok", organizationID: "555")
        api.failure = .offline
        await store.stop()
        XCTAssertTrue(store.hasPendingWork)

        api.entries = [] // Deleted on the web before the Mac is back online: Productive answers 404.
        api.failure = nil
        clock = clock.addingTimeInterval(60)
        await store.refresh()
        XCTAssertTrue(store.pending.isEmpty, "a refused change cannot block every later refresh")
        XCTAssertFalse(store.hasPendingWork, "nor an automatic update")
        XCTAssertTrue(store.lastError?.contains("refused") == true, "the user sees why the change is gone")
        XCTAssertFalse(store.isOffline)

        await store.refresh()
        XCTAssertNil(store.lastError, "the next refresh is clean")
    }

    func testPendingWorkWhileARequestRuns() async {
        let store = await connectedStore()
        XCTAssertFalse(store.hasPendingWork, "idle after the first load")
        api.createDelay = 0.3
        let start = Task { await store.start(cro) }
        // `start` shows the timer and queues its request in one step, before its first suspension.
        while !store.isRunning { await Task.yield() }
        XCTAssertTrue(store.hasPendingWork, "the start is still on its way to Productive")
        await start.value
        XCTAssertFalse(store.hasPendingWork)
    }

    func testOfflineStopCorrectsEntryTime() async {
        var clock = Date()
        api.entries = [TimeEntry(id: "501", day: Day(clock), minutes: 30, note: "", service: cro)]
        api.timers = [RunningTimer(id: "7001", startedAt: clock.addingTimeInterval(-10 * 60), timeEntryID: "501")]
        let store = TimeStore(settings: settings, tokenStore: MemoryTokenStore(), makeAPI: { [api] _ in api! }, clock: { clock })
        await store.connect(token: "tok", organizationID: "555")
        XCTAssertTrue(store.isRunning)

        api.failure = .offline
        await store.stop()
        XCTAssertFalse(store.isRunning)

        clock = clock.addingTimeInterval(30 * 60) // Back online 30 minutes later.
        api.failure = nil
        await store.refresh()
        XCTAssertTrue(api.calls.contains("update 501 40"), "30 base + 10 minutes to the stop click, not the reconnect time")
    }

    func testUnauthorizedOnRefreshReturnsToSetup() async {
        let store = await connectedStore()
        api.failure = .unauthorized
        await store.refresh()
        XCTAssertEqual(store.phase, .setup)
    }

    func testEditAndDelete() async {
        api.entries = [TimeEntry(id: "501", day: Day(Date()), minutes: 30, note: "", service: cro)]
        let store = await connectedStore()
        let entry = store.entries[0]
        let ok = await store.updateEntry(entry, minutes: 90, note: "QA")
        XCTAssertTrue(ok)
        XCTAssertEqual(store.entries[0].minutes, 90)
        XCTAssertEqual(store.entries[0].note, "QA")
        let deleted = await store.deleteEntry(store.entries[0])
        XCTAssertTrue(deleted)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testEditServiceAndDate() async {
        let other = Service(id: "9002", name: "Internal meetings")
        api.services = [cro, other]
        api.entries = [TimeEntry(id: "501", day: Day(Date()), minutes: 30, note: "", service: cro)]
        let store = await connectedStore()
        let yesterday = Day(Date()).adding(days: -1)
        let ok = await store.updateEntry(store.entries[0], changes: EntryChanges(serviceID: other.id, day: yesterday))
        XCTAssertTrue(ok)
        XCTAssertEqual(store.entries[0].service.id, other.id)
        XCTAssertEqual(store.entries[0].day, yesterday)
        XCTAssertEqual(store.entries[0].minutes, 30, "time does not change")
    }

    func testRunningEntryOnlyChangesNote() async {
        let other = Service(id: "9002", name: "Internal meetings")
        api.services = [cro, other]
        api.entries = [TimeEntry(id: "501", day: Day(Date()), minutes: 30, note: "", service: cro)]
        api.timers = [RunningTimer(id: "7001", startedAt: Date(), timeEntryID: "501")]
        let store = await connectedStore()
        _ = await store.updateEntry(store.entries[0], changes: EntryChanges(minutes: 5, note: "QA", serviceID: other.id))
        XCTAssertEqual(api.entries[0].service.id, cro.id)
        XCTAssertEqual(api.entries[0].minutes, 30)
        XCTAssertEqual(api.entries[0].note, "QA")
    }

    func testJiraEntryGetsExperimentCodeNoteOnce() async {
        let jira = JiraLink(key: "WT-558", summary: "WT E97 Checkout Test 1", url: nil)
        api.entries = [TimeEntry(id: "501", day: Day(Date()), minutes: 30, note: "", service: cro, jira: jira),
                       TimeEntry(id: "502", day: Day(Date()), minutes: 10, note: "Kept", service: cro, jira: jira),
                       TimeEntry(id: "503", day: Day(Date()), minutes: 10, note: "", service: cro, isLocked: true, jira: jira)]
        let store = await connectedStore()
        XCTAssertEqual(store.entries.first { $0.id == "501" }?.note, "E97")
        XCTAssertEqual(store.entries.first { $0.id == "501" }?.jira, jira, "the Jira link stays after the update")
        XCTAssertEqual(api.entries.first { $0.id == "502" }?.note, "Kept")
        XCTAssertEqual(api.entries.first { $0.id == "503" }?.note, "")
        await store.refresh()
        XCTAssertEqual(api.calls.filter { $0.hasPrefix("update") }.count, 1)
    }

    func testBareCodeNoteIsUpgradedToQA() async {
        let qa = JiraLink(key: "NWR-539", summary: "NWR E83 QA - Sticky Product Gallery", url: nil)
        api.entries = [TimeEntry(id: "501", day: Day(Date()), minutes: 30, note: "E83", service: cro, jira: qa),
                       TimeEntry(id: "502", day: Day(Date()), minutes: 10, note: "E83 handover", service: cro, jira: qa)]
        let store = await connectedStore()
        XCTAssertEqual(store.entries.first { $0.id == "501" }?.note, "E83 QA")
        XCTAssertEqual(api.entries.first { $0.id == "502" }?.note, "E83 handover", "a note the user wrote stays")
    }

    func testRemoveIdleTimeAndContinue() async {
        let start = Date().addingTimeInterval(-40 * 60)
        api.entries = [TimeEntry(id: "501", day: Day(Date()), minutes: 30, note: "E97", service: cro)]
        api.timers = [RunningTimer(id: "7001", startedAt: start, timeEntryID: "501")]
        let store = await connectedStore()
        XCTAssertEqual(store.runningSeconds / 60, 70)
        // Idle since 25 minutes after the start: keep 30 + 25.
        await store.removeIdleTime(since: start.addingTimeInterval(25 * 60), keepRunning: true)
        XCTAssertEqual(api.entries[0].minutes, 55)
        XCTAssertTrue(store.isRunning)
        XCTAssertEqual(store.runningEntry?.id, "501")
        XCTAssertEqual(store.runningSeconds / 60, 55, "continues from the kept time")
        XCTAssertEqual(api.timers.filter(\.isRunning).count, 1)
    }

    func testRemoveIdleTimeAndStop() async {
        let start = Date().addingTimeInterval(-40 * 60)
        api.entries = [TimeEntry(id: "501", day: Day(Date()), minutes: 0, note: "", service: cro)]
        api.timers = [RunningTimer(id: "7001", startedAt: start, timeEntryID: "501")]
        let store = await connectedStore()
        await store.removeIdleTime(since: start.addingTimeInterval(10 * 60), keepRunning: false)
        XCTAssertEqual(api.entries[0].minutes, 10)
        XCTAssertFalse(store.isRunning)
        XCTAssertEqual(api.timers.filter(\.isRunning).count, 0)
    }

    func testFavouriteReplacementAfterBudgetChange() async {
        settings.favourites = [Favourite(service: Service(id: "100", name: "CRO Development", clientName: "Northwind Retail"))]
        let store = await connectedStore()
        XCTAssertEqual(store.replacements["100"], cro)
        store.acceptReplacement(for: store.favourites[0])
        XCTAssertEqual(store.favourites.map(\.serviceID), ["9001"])
        XCTAssertTrue(store.replacements.isEmpty)
    }
}
