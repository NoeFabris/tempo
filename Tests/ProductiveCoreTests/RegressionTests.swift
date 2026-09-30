import XCTest
@testable import ProductiveCore

/// Wraps MockAPI and can hold a call until the test releases it.
final class GatedAPI: ProductiveAPI, @unchecked Sendable {
    let inner: MockAPI
    var holdTimers = false
    var holdCreate = false
    var gate: CheckedContinuation<Void, Never>?

    init(_ inner: MockAPI) { self.inner = inner }

    func me() async throws -> Person { try await inner.me() }
    func recentTimers(personID: String) async throws -> [RunningTimer] {
        let snapshot = try await inner.recentTimers(personID: personID)
        if holdTimers { holdTimers = false; await withCheckedContinuation { gate = $0 } }
        return snapshot
    }
    func timeEntries(personID: String, from: Day, to: Day) async throws -> [TimeEntry] {
        try await inner.timeEntries(personID: personID, from: from, to: to)
    }
    func trackableServices(personID: String) async throws -> [Service] { try await inner.trackableServices(personID: personID) }
    func createTimeEntry(personID: String, serviceID: String, day: Day, minutes: Int, note: String) async throws -> TimeEntry {
        if holdCreate { holdCreate = false; await withCheckedContinuation { gate = $0 } }
        return try await inner.createTimeEntry(personID: personID, serviceID: serviceID, day: day, minutes: minutes, note: note)
    }
    func updateTimeEntry(id: String, minutes: Int?, note: String?) async throws -> TimeEntry {
        try await inner.updateTimeEntry(id: id, minutes: minutes, note: note)
    }
    func deleteTimeEntry(id: String) async throws { try await inner.deleteTimeEntry(id: id) }
    func startTimer(timeEntryID: String) async throws -> RunningTimer { try await inner.startTimer(timeEntryID: timeEntryID) }
    func stopTimer(id: String) async throws -> RunningTimer { try await inner.stopTimer(id: id) }

    func waitForGate() async { while gate == nil { await Task.yield() } }
}

@MainActor
final class RegressionTests: XCTestCase {
    let cro = Service(id: "9001", name: "CRO Development", clientName: "Northwind Retail")

    func settings() -> SettingsStore { SettingsStore(defaults: UserDefaults(suiteName: "regression-\(UUID().uuidString)")!) }

    /// Review #1: a refresh in flight when the user stops must not bring the timer back.
    func testInFlightRefreshDoesNotResurrectStoppedTimer() async {
        let mock = MockAPI()
        mock.services = [cro]
        mock.entries = [TimeEntry(id: "501", day: Day(Date()), minutes: 30, note: "", service: cro)]
        mock.timers = [RunningTimer(id: "7001", startedAt: Date().addingTimeInterval(-600), timeEntryID: "501")]
        let api = GatedAPI(mock)
        let store = TimeStore(settings: settings(), tokenStore: MemoryTokenStore(), makeAPI: { _ in api })
        await store.connect(token: "t", organizationID: "1")
        XCTAssertTrue(store.isRunning)

        api.holdTimers = true
        let refresh = Task { await store.refresh() }
        await api.waitForGate()
        let stop = Task { await store.stop() }
        await Task.yield()
        XCTAssertFalse(store.isRunning, "the stop shows at once")
        api.gate?.resume()
        await refresh.value
        await stop.value

        XCTAssertFalse(store.isRunning)
        XCTAssertNotNil(mock.timers.first { $0.id == "7001" }?.stoppedAt, "the server timer is stopped")
    }

    /// Review #2: a stop while the flush sends a queued start must stop the new server timer.
    func testStopDuringFlushStopsServerTimer() async {
        let mock = MockAPI()
        mock.services = [cro]
        var clock = Date()
        let api = GatedAPI(mock)
        let store = TimeStore(settings: settings(), tokenStore: MemoryTokenStore(), makeAPI: { _ in api }, clock: { clock })
        await store.connect(token: "t", organizationID: "1")

        mock.failure = .offline
        await store.start(cro)
        mock.failure = nil
        clock = clock.addingTimeInterval(20 * 60)

        api.holdCreate = true
        let refresh = Task { await store.refresh() }
        await api.waitForGate()
        let stop = Task { await store.stop() }
        await Task.yield()
        api.gate?.resume()
        await refresh.value
        await stop.value

        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertEqual(mock.timers.filter(\.isRunning).count, 0, "no timer left running in Productive")
        XCTAssertFalse(store.isRunning)
    }

    /// Review #3: an offline continue of an entry, then a stop, adds the session once.
    func testOfflineContinueCountsOnce() async {
        let mock = MockAPI()
        mock.services = [cro]
        var clock = Date()
        mock.entries = [TimeEntry(id: "501", day: Day(clock), minutes: 60, note: "", service: cro)]
        let store = TimeStore(settings: settings(), tokenStore: MemoryTokenStore(), makeAPI: { _ in mock }, clock: { clock })
        await store.connect(token: "t", organizationID: "1")

        mock.failure = .offline
        await store.start(cro)
        clock = clock.addingTimeInterval(30 * 60)
        await store.stop()
        mock.failure = nil
        await store.refresh()

        XCTAssertEqual(mock.entries.first { $0.id == "501" }?.minutes, 90)
        XCTAssertTrue(store.pending.isEmpty)
    }

    /// Review #4: a stop that Productive refuses restores the timer with the same time.
    func testFailedStopRestoresSameTime() async {
        let mock = MockAPI()
        mock.services = [cro]
        let clock = Date()
        mock.entries = [TimeEntry(id: "501", day: Day(clock), minutes: 30, note: "", service: cro)]
        mock.timers = [RunningTimer(id: "7001", startedAt: clock.addingTimeInterval(-10 * 60), timeEntryID: "501")]
        let store = TimeStore(settings: settings(), tokenStore: MemoryTokenStore(), makeAPI: { _ in mock }, clock: { clock })
        await store.connect(token: "t", organizationID: "1")
        XCTAssertEqual(store.runningSeconds / 60, 40)

        mock.failure = .http(status: 500, message: "boom")
        await store.stop()

        XCTAssertTrue(store.isRunning)
        XCTAssertEqual(store.runningSeconds / 60, 40)
        XCTAssertEqual(store.entries.first { $0.id == "501" }?.minutes, 30)
        XCTAssertNotNil(store.lastError)
    }

    /// Review #6: a double click on the same service starts one timer.
    func testDoubleStartMakesOneTimer() async {
        let mock = MockAPI()
        mock.services = [cro]
        let store = TimeStore(settings: settings(), tokenStore: MemoryTokenStore(), makeAPI: { _ in mock })
        await store.connect(token: "t", organizationID: "1")
        async let first: Void = store.start(cro)
        async let second: Void = store.start(cro)
        _ = await (first, second)
        XCTAssertEqual(mock.calls.filter { $0.hasPrefix("create") }.count, 1)
        XCTAssertEqual(mock.timers.filter(\.isRunning).count, 1)
    }

    /// Review #7: connecting another account clears the old account's queue.
    func testConnectToOtherAccountClearsQueue() async {
        let mock = MockAPI()
        mock.services = [cro]
        let store = TimeStore(settings: settings(), tokenStore: MemoryTokenStore(), makeAPI: { _ in mock })
        await store.connect(token: "t", organizationID: "1")
        mock.failure = .offline
        await store.start(cro)
        XCTAssertFalse(store.pending.isEmpty)
        mock.failure = nil
        mock.person = Person(id: "88", name: "Colleague")
        let callsBefore = mock.calls.count
        await store.connect(token: "t2", organizationID: "1")
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertFalse(mock.calls.dropFirst(callsBefore).contains { $0.hasPrefix("create") },
                       "the old start is not sent for the new person")
    }

    /// Review #10: accepting a replacement that is already a favourite leaves no duplicate.
    func testReplacementDoesNotDuplicateFavourite() async {
        let s = settings()
        s.favourites = [Favourite(service: Service(id: "100", name: "CRO Development", clientName: "Northwind Retail")),
                        Favourite(service: cro)]
        let mock = MockAPI()
        mock.services = [cro]
        let store = TimeStore(settings: s, tokenStore: MemoryTokenStore(), makeAPI: { _ in mock })
        await store.connect(token: "t", organizationID: "1")
        store.acceptReplacement(for: store.favourites[0])
        XCTAssertEqual(store.favourites.map(\.serviceID), ["9001"])
    }

    /// Review #12: the day changes even when an action reads the clock first after midnight.
    func testMidnightViaAction() async {
        let mock = MockAPI()
        mock.services = [cro]
        var clock = Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: Date())!
        let store = TimeStore(settings: settings(), tokenStore: MemoryTokenStore(), makeAPI: { _ in mock }, clock: { clock })
        await store.connect(token: "t", organizationID: "1")
        let before = store.selectedDay
        clock = clock.addingTimeInterval(120)
        await store.refresh()
        XCTAssertEqual(store.selectedDay, before.adding(days: 1))
    }

    /// Review #5: a timeout on a POST is not "offline", so it is not queued and sent a second time.
    func testTimeoutOnPostIsNotOffline() {
        XCTAssertEqual(ProductiveClient.map(URLError(.timedOut), method: "POST"),
                       .transport(URLError(.timedOut).localizedDescription))
        XCTAssertEqual(ProductiveClient.map(URLError(.timedOut), method: "GET"), .offline)
        XCTAssertEqual(ProductiveClient.map(URLError(.notConnectedToInternet), method: "POST"), .offline)
    }
}
