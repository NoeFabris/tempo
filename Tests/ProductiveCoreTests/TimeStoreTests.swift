import XCTest
@testable import ProductiveCore

final class MockAPI: ProductiveAPI, @unchecked Sendable {
    var person = Person(id: "77", name: "Noe Fabris")
    var entries: [TimeEntry] = []
    var timers: [RunningTimer] = []
    var services: [Service] = []
    var failure: ProductiveError?
    var calls: [String] = []
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
        let service = services.first { $0.id == serviceID } ?? Service(id: serviceID, name: "S")
        let e = TimeEntry(id: newID(), day: day, minutes: minutes, note: note, service: service)
        entries.append(e)
        return e
    }

    func updateTimeEntry(id: String, minutes: Int?, note: String?) async throws -> TimeEntry {
        try check("update \(id) \(minutes.map(String.init) ?? "-")")
        let i = entries.firstIndex { $0.id == id }!
        if let minutes { entries[i].minutes = minutes }
        if let note { entries[i].note = note }
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
    init(_ token: String? = nil) { self.token = token }
    func read() -> String? { token }
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
        XCTAssertEqual(store.pending, [.log(service: cro, day: Day(clock), minutes: 25)])

        api.failure = nil
        await store.refresh()
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertFalse(store.isOffline)
        XCTAssertTrue(api.calls.contains("create 9001 25"))
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

    func testFavouriteReplacementAfterBudgetChange() async {
        settings.favourites = [Favourite(service: Service(id: "100", name: "CRO Development", clientName: "Northwind Retail"))]
        let store = await connectedStore()
        XCTAssertEqual(store.replacements["100"], cro)
        store.acceptReplacement(for: store.favourites[0])
        XCTAssertEqual(store.favourites.map(\.serviceID), ["9001"])
        XCTAssertTrue(store.replacements.isEmpty)
    }
}
