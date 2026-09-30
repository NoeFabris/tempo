import XCTest
@testable import ProductiveCore

func fixture(_ name: String) throws -> Document {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
}

final class MappingTests: XCTestCase {
    func testTimeEntriesMapWithServiceLabels() throws {
        let doc = try fixture("time_entries")
        let index = ResourceIndex(doc.data + doc.included)
        let entries = doc.data.compactMap { Mapping.timeEntry($0, index) }

        XCTAssertEqual(entries.count, 2)
        let first = entries[0]
        XCTAssertEqual(first.day.iso, "2026-09-30")
        XCTAssertEqual(first.minutes, 190)
        XCTAssertEqual(first.note, "Built the PDP test & QA")
        XCTAssertEqual(first.service.name, "CRO Development")
        XCTAssertEqual(first.service.clientName, "Northwind Retail Limited")
        XCTAssertEqual(first.service.projectName, "[NWR] NWR - Full service experimentation")
        XCTAssertEqual(first.service.budgetName, "[NWR] NWR - Full service experimentation - Budget (Sep 2026)")
        XCTAssertFalse(first.isLocked)

        XCTAssertEqual(entries[1].note, "")
        XCTAssertFalse(entries[1].isLocked, "approved entries can still be editable")
        XCTAssertEqual(entries[1].service.context, "")
        XCTAssertEqual(doc.totalPages, 1)
    }

    func testTimersMap() throws {
        let doc = try fixture("timers")
        let timers = doc.data.compactMap { Mapping.timer($0, ResourceIndex(doc.data)) }
        XCTAssertEqual(timers.count, 2)
        XCTAssertTrue(timers[0].isRunning)
        XCTAssertEqual(timers[0].timeEntryID, "501")
        XCTAssertEqual(timers[0].startedAt, Mapping.parseDate("2026-09-30T08:15:00Z"))
        XCTAssertFalse(timers[1].isRunning)
    }

    func testPersonFromMemberships() throws {
        let doc = try fixture("memberships")
        XCTAssertEqual(Mapping.person(fromMemberships: doc, organizationID: "555"), Person(id: "77", name: "Noe Fabris"))
    }

    func testSingleResourceDocumentAndNumericIDs() throws {
        let json = #"{"data":{"id":12,"type":"timers","attributes":{"started_at":"2026-09-30T10:00:00Z","time_entry_id":501}}}"#
        let doc = try JSONDecoder().decode(Document.self, from: Data(json.utf8))
        let timer = try XCTUnwrap(Mapping.timer(doc.data[0], ResourceIndex([])))
        XCTAssertEqual(timer.id, "12")
        XCTAssertEqual(timer.timeEntryID, "501")
    }
}

final class TimeFormatTests: XCTestCase {
    func testHM() {
        XCTAssertEqual(TimeFormat.hm(0), "0:00")
        XCTAssertEqual(TimeFormat.hm(45), "0:45")
        XCTAssertEqual(TimeFormat.hm(125), "2:05")
        XCTAssertEqual(TimeFormat.hm(-5), "0:00")
        XCTAssertEqual(TimeFormat.hms(seconds: 3725), "1:02:05")
    }

    func testParse() {
        XCTAssertEqual(TimeFormat.parseMinutes("1:30"), 90)
        XCTAssertEqual(TimeFormat.parseMinutes(":45"), 45)
        XCTAssertEqual(TimeFormat.parseMinutes("1.5"), 90)
        XCTAssertEqual(TimeFormat.parseMinutes("1,25"), 75)
        XCTAssertEqual(TimeFormat.parseMinutes("2"), 120)
        XCTAssertEqual(TimeFormat.parseMinutes("2h"), 120)
        XCTAssertEqual(TimeFormat.parseMinutes("45m"), 45)
        XCTAssertNil(TimeFormat.parseMinutes("1:75"))
        XCTAssertNil(TimeFormat.parseMinutes("abc"))
        XCTAssertNil(TimeFormat.parseMinutes(""))
    }
}

final class WeekTests: XCTestCase {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }

    func testMondayWeek() {
        // 2026-09-30 is a Wednesday.
        let days = Week.days(containing: Day(iso: "2026-09-30")!, firstWeekday: 2, calendar: calendar)
        XCTAssertEqual(days.map(\.iso), ["2026-09-28", "2026-09-29", "2026-09-30", "2026-10-01",
                                         "2026-10-02", "2026-10-03", "2026-10-04"])
    }

    func testSundayWeek() {
        let days = Week.days(containing: Day(iso: "2026-09-27")!, firstWeekday: 1, calendar: calendar)
        XCTAssertEqual(days.first?.iso, "2026-09-27")
        XCTAssertEqual(days.last?.iso, "2026-10-03")
    }

    func testTotals() {
        let s = Service(id: "1", name: "A")
        let d = Day(iso: "2026-09-30")!
        let totals = Week.totals([TimeEntry(id: "1", day: d, minutes: 30, note: "", service: s),
                                  TimeEntry(id: "2", day: d, minutes: 15, note: "", service: s)])
        XCTAssertEqual(totals[d], 45)
    }
}

final class FavouriteMatcherTests: XCTestCase {
    let sep = Service(id: "100", name: "CRO Development", budgetName: "Budget (Sep 2026)", projectName: "NWR", clientName: "Northwind Retail")

    func testCurrentWhenStillOpen() {
        XCTAssertEqual(FavouriteMatcher.resolve(Favourite(service: sep), in: [sep]), .current(sep))
    }

    func testReplacementPicksNewestSameLabel() {
        let oct = Service(id: "180", name: "CRO Development", budgetName: "Budget (Oct 2026)", projectName: "NWR", clientName: "Northwind Retail")
        let old = Service(id: "90", name: "cro development ", budgetName: "Budget (Aug 2026)", projectName: "NWR", clientName: "northwind retail")
        let other = Service(id: "999", name: "Design", budgetName: "Budget (Oct 2026)", projectName: "NWR", clientName: "Northwind Retail")
        XCTAssertEqual(FavouriteMatcher.resolve(Favourite(service: sep), in: [old, oct, other]), .replacement(oct))
    }

    func testFallsBackToClientAndService() {
        let moved = Service(id: "200", name: "CRO Development", budgetName: "Retainer", projectName: "NWR 2027", clientName: "Northwind Retail")
        XCTAssertEqual(FavouriteMatcher.resolve(Favourite(service: sep), in: [moved]), .replacement(moved))
    }

    func testMissing() {
        XCTAssertEqual(FavouriteMatcher.resolve(Favourite(service: sep), in: []), .missing)
    }
}

final class ClientTests: XCTestCase {
    func testRequestHeadersAndQuery() throws {
        let client = ProductiveClient(config: ProductiveConfig(token: "tok", organizationID: "555"))
        let req = try client.makeRequest("GET", "time_entries", query: ["filter[person_id]": "77"], body: nil)
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Auth-Token"), "tok")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Organization-Id"), "555")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/vnd.api+json")
        XCTAssertEqual(req.url?.absoluteString, "https://api.productive.io/api/v2/time_entries?filter%5Bperson_id%5D=77")
    }

    func testErrorMessage() {
        let data = Data(#"{"errors":[{"title":"Invalid","detail":"service is closed"}]}"#.utf8)
        XCTAssertEqual(ProductiveClient.errorMessage(data), "Invalid: service is closed")
    }
}
