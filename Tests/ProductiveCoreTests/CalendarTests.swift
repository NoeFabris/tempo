import XCTest
@testable import ProductiveCore

final class CalendarMappingTests: XCTestCase {
    func testMapsOutlookEvent() throws {
        // Shape of a real Productive calendar_events response (values shortened).
        let json = #"""
        {"data":[{"id":"1","type":"calendar_events","attributes":{
          "event_id":"AAMk-1","name":"Daily stand-up","start_date":null,"end_date":null,
          "start_time":"2026-09-30T08:30:00.000Z","end_time":"2026-09-30T09:00:00.000Z",
          "organizer_name":"Organizer","calendar":"Outlook","event_type":"busy",
          "recurring_event_id":"SERIES-1","response_status":"accepted"}}]}
        """#
        let doc = try JSONDecoder().decode(Document.self, from: Data(json.utf8))
        let e = try XCTUnwrap(Mapping.calendarEvent(doc.data[0]))
        XCTAssertEqual(e.name, "Daily stand-up")
        XCTAssertEqual(e.minutes, 30)
        XCTAssertEqual(e.seriesKey, "SERIES-1")
        XCTAssertFalse(e.isAllDay)
        XCTAssertTrue(e.isLoggable)
        XCTAssertTrue(e.id.hasPrefix("AAMk-1@"))
    }

    func testLoggableRules() {
        let start = Date()
        XCTAssertFalse(CalendarEvent(id: "a", name: "x", start: start, end: start.addingTimeInterval(1800), responseStatus: "declined").isLoggable)
        XCTAssertFalse(CalendarEvent(id: "b", name: "x", start: start, end: start.addingTimeInterval(1800), eventType: "free").isLoggable)
        XCTAssertFalse(CalendarEvent(id: "c", name: "x", start: start, end: start.addingTimeInterval(86400), isAllDay: true).isLoggable)
        XCTAssertEqual(CalendarEvent(id: "d", name: "Ad Hoc", start: start, end: start).seriesKey, "name:ad hoc")
    }
}

@MainActor
final class CalendarStoreTests: XCTestCase {
    func testLogMeetingRemembersEntryAndService() async {
        let api = MockAPI()
        let cro = Service(id: "9001", name: "CRO Development", clientName: "Northwind Retail")
        api.services = [cro]
        let today = Day(Date())
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(9.5 * 3600)
        let daily = CalendarEvent(id: "ev1", name: "Daily stand-up", start: start, end: start.addingTimeInterval(1800), seriesID: "S1")
        let declined = CalendarEvent(id: "ev2", name: "Skip", start: start, end: start.addingTimeInterval(1800), responseStatus: "declined")
        api.events[today] = [daily, declined]
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "cal-\(UUID())")!)
        let store = TimeStore(settings: settings, tokenStore: MemoryTokenStore(), makeAPI: { _ in api })
        await store.connect(token: "t", organizationID: "1")

        XCTAssertEqual(store.meetings(on: today).map(\.id), ["ev1"], "declined meetings are not listed")
        XCTAssertNil(store.rememberedService(for: daily))

        await store.addEntry(service: cro, day: today, minutes: daily.minutes, note: daily.name, event: daily)
        XCTAssertEqual(store.loggedEntry(for: daily)?.minutes, 30)
        XCTAssertEqual(store.loggedEntry(for: daily)?.note, "Daily stand-up")

        // The next occurrence of the series gets the same service.
        let tomorrow = CalendarEvent(id: "ev3", name: "Daily stand-up", start: start.addingTimeInterval(86400),
                                     end: start.addingTimeInterval(86400 + 1800), seriesID: "S1")
        XCTAssertEqual(store.rememberedService(for: tomorrow), cro)
        XCTAssertNil(store.loggedEntry(for: tomorrow))
    }

    func testCalendarErrorsAreIgnored() async {
        let api = MockAPI()
        let store = TimeStore(settings: SettingsStore(defaults: UserDefaults(suiteName: "cal-\(UUID())")!),
                              tokenStore: MemoryTokenStore(), makeAPI: { _ in api })
        await store.connect(token: "t", organizationID: "1")
        api.failure = .http(status: 403, message: "no calendar")
        await store.loadCalendar(Day(Date()).adding(days: 1))
        api.failure = nil
        XCTAssertTrue(store.meetings(on: Day(Date()).adding(days: 1)).isEmpty)
        XCTAssertNil(store.lastError, "a missing calendar is not an error")
    }
}
