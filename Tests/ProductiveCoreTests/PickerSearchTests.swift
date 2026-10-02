import XCTest
@testable import ProductiveCore

/// The picker search lives in the app target; this mirrors its matching rules on the core model
/// through `Service` fields, and checks the data the search depends on.
final class ServiceDataTests: XCTestCase {
    func testSectionMapsFromIncluded() throws {
        let json = #"""
        {"data":[{"id":"1","type":"services","attributes":{"name":"CRO Consultant","position":7},
          "relationships":{"deal":{"data":{"type":"deals","id":"9"}},"section":{"data":{"type":"sections","id":"5"}}}}],
         "included":[{"id":"9","type":"deals","attributes":{"name":"Wingtip - FY26 - Budget (Sep 2026)"},
                      "relationships":{"company":{"data":{"type":"companies","id":"3"}}}},
                     {"id":"3","type":"companies","attributes":{"name":"Wingtip Online Ltd"}},
                     {"id":"5","type":"sections","attributes":{"name":"Experiment (Full Service)"}}]}
        """#
        let doc = try JSONDecoder().decode(Document.self, from: Data(json.utf8))
        let s = Mapping.service(doc.data[0], ResourceIndex(doc.data + doc.included))
        XCTAssertEqual(s.section, "Experiment (Full Service)")
        XCTAssertEqual(s.position, 7)
        XCTAssertEqual(s.shortClientName, "Wingtip Online")
    }

    func testOldStoredServiceWithoutSectionStillDecodes() throws {
        let old = #"{"id":"1","name":"CRO Development","budgetName":"B","projectName":"P","clientName":"C"}"#
        let s = try JSONDecoder().decode(Service.self, from: Data(old.utf8))
        XCTAssertNil(s.sectionName)
        XCTAssertEqual(s.section, "")
        XCTAssertNil(s.budgetEnd)
        XCTAssertFalse(s.budgetEndedBeforeMonth(of: Day(iso: "2030-01-01")!), "no end date: never from an earlier month")
    }

    /// Every month of a recurring budget has the same name; the suffix tells them apart, as in Productive.
    func testRecurringBudgetGetsItsSuffixAndEndDate() throws {
        let json = #"""
        {"data":[{"id":"1","type":"services","attributes":{"name":"Account Management"},
          "relationships":{"deal":{"data":{"type":"deals","id":"9"}}}},
                 {"id":"2","type":"services","attributes":{"name":"CRO Development"},
          "relationships":{"deal":{"data":{"type":"deals","id":"10"}}}}],
         "included":[{"id":"9","type":"deals","attributes":{"name":"Webcare Basic","date":"2026-10-01",
                                                          "end_date":"2026-10-31","suffix":"2026/10"}},
                     {"id":"10","type":"deals","attributes":{"name":"Wingtip - FY26 - Budget (Sep 2026)",
                                                           "end_date":"2026-09-30","suffix":null}}]}
        """#
        let doc = try JSONDecoder().decode(Document.self, from: Data(json.utf8))
        let index = ResourceIndex(doc.data + doc.included)
        let recurring = Mapping.service(doc.data[0], index)
        XCTAssertEqual(recurring.budgetName, "Webcare Basic (2026/10)")
        XCTAssertEqual(recurring.budgetEnd, Day(iso: "2026-10-31"))
        let monthly = Mapping.service(doc.data[1], index)
        XCTAssertEqual(monthly.budgetName, "Wingtip - FY26 - Budget (Sep 2026)", "no suffix: the name stays")
        XCTAssertEqual(monthly.budgetEnd, Day(iso: "2026-09-30"))
    }

    func testBudgetFromAnEarlierMonth() {
        let september = Service(id: "1", name: "CRO Development", budgetEnd: Day(iso: "2026-09-30"))
        XCTAssertFalse(september.budgetEndedBeforeMonth(of: Day(iso: "2026-09-30")!), "its own month")
        XCTAssertFalse(september.budgetEndedBeforeMonth(of: Day(iso: "2026-09-02")!))
        XCTAssertTrue(september.budgetEndedBeforeMonth(of: Day(iso: "2026-10-01")!))
        XCTAssertTrue(september.budgetEndedBeforeMonth(of: Day(iso: "2027-01-15")!))
        let december = Service(id: "2", name: "CRO Development", budgetEnd: Day(iso: "2025-12-31"))
        XCTAssertTrue(december.budgetEndedBeforeMonth(of: Day(iso: "2026-01-01")!), "across the year")
        let rolling = Service(id: "3", name: "Web retainer", budgetEnd: Day(iso: "2026-10-18"))
        XCTAssertFalse(rolling.budgetEndedBeforeMonth(of: Day(iso: "2026-10-02")!), "ends later this month")
    }

    func testStoredServiceKeepsItsEndDate() throws {
        let service = Service(id: "1", name: "CRO Development", budgetEnd: Day(iso: "2026-09-30"))
        let decoded = try JSONDecoder().decode(Service.self, from: JSONEncoder().encode(service))
        XCTAssertEqual(decoded, service)
    }

    @MainActor
    func testClientCodesFromJiraKeys() async {
        let api = MockAPI()
        let wingtip = Service(id: "1", name: "CRO Development", clientName: "Wingtip Online Ltd")
        api.services = [wingtip]
        api.entries = [TimeEntry(id: "5", day: Day(Date()), minutes: 1, note: "E97", service: wingtip,
                                 jira: JiraLink(key: "WT-558", summary: "", url: nil))]
        let store = TimeStore(settings: SettingsStore(defaults: UserDefaults(suiteName: "codes-\(UUID())")!),
                              tokenStore: MemoryTokenStore(), makeAPI: { _ in api })
        await store.connect(token: "t", organizationID: "1")
        XCTAssertEqual(store.clientCodes, ["wt": "Wingtip Online Ltd"])
        XCTAssertEqual(store.recentServices.map(\.id), ["1"])
    }

    /// Productive returns entries in no fixed order: inside a day, the newest entry (highest id) comes first.
    @MainActor
    func testRecentServicesNewestFirstInsideADay() async {
        let api = MockAPI()
        let today = Day(Date())
        let services = ["A", "B", "C", "D"].map { Service(id: $0, name: "Service \($0)") }
        api.services = services
        api.entries = [TimeEntry(id: "100", day: today, minutes: 1, note: "", service: services[0]),
                       TimeEntry(id: "102", day: today, minutes: 1, note: "", service: services[1]),
                       TimeEntry(id: "101", day: today, minutes: 1, note: "", service: services[2]),
                       TimeEntry(id: "999", day: today.adding(days: -1), minutes: 1, note: "", service: services[3])]
        let store = TimeStore(settings: SettingsStore(defaults: UserDefaults(suiteName: "recent-\(UUID())")!),
                              tokenStore: MemoryTokenStore(), makeAPI: { _ in api })
        await store.connect(token: "t", organizationID: "1")
        let yesterdayInWeek = store.weekDays.contains(today.adding(days: -1))
        XCTAssertEqual(store.recentServices.map(\.id), ["B", "C", "A"] + (yesterdayInWeek ? ["D"] : []))
    }

    func testErrorMessageNamesTheRefusedField() {
        let body = #"{"errors":[{"status":"422","title":"can't be blank","source":{"pointer":"/data/attributes/note"}}]}"#
        XCTAssertEqual(ProductiveClient.errorMessage(Data(body.utf8)), "note: can't be blank")
        let named = #"{"errors":[{"title":"Invalid","detail":"Note is required","source":{"pointer":"/data/attributes/note"}}]}"#
        XCTAssertEqual(ProductiveClient.errorMessage(Data(named.utf8)), "Invalid: Note is required", "no field twice")
        XCTAssertTrue(ProductiveError.http(status: 422, message: "note: can't be blank").isAboutNote)
        XCTAssertFalse(ProductiveError.http(status: 500, message: "note").isAboutNote)
    }

    func testTimeEntryRequirementsOfTheBudget() throws {
        let json = #"""
        {"data":[{"id":"1","type":"services","attributes":{"name":"Internal initiatives"},
          "relationships":{"deal":{"data":{"type":"deals","id":"9"}}}},
                 {"id":"2","type":"services","attributes":{"name":"CRO Development"},
          "relationships":{"deal":{"data":{"type":"deals","id":"10"}}}}],
         "included":[{"id":"9","type":"deals","attributes":{"name":"Internal","time_entry_requirements":["note"]}},
                     {"id":"10","type":"deals","attributes":{"name":"Retainer"}}]}
        """#
        let doc = try JSONDecoder().decode(Document.self, from: Data(json.utf8))
        let index = ResourceIndex(doc.data + doc.included)
        XCTAssertEqual(Mapping.service(doc.data[0], index).requiresNote, true)
        XCTAssertNil(Mapping.service(doc.data[1], index).requiresNote, "unknown when Productive does not send it")
    }

    func testRefusalIsAnAnswerNotANetworkError() {
        XCTAssertTrue(ProductiveError.http(status: 404, message: "").isRefusal)
        XCTAssertTrue(ProductiveError.http(status: 422, message: "").isRefusal)
        XCTAssertFalse(ProductiveError.http(status: 500, message: "").isRefusal, "a server error can pass")
        XCTAssertFalse(ProductiveError.offline.isRefusal)
        XCTAssertFalse(ProductiveError.rateLimited.isRefusal)
        XCTAssertFalse(ProductiveError.unauthorized.isRefusal)
    }
}

final class ServiceSearchTests: XCTestCase {
    let services = [
        Service(id: "1", name: "CRO Development", budgetName: "Wingtip - FY26 - Budget (Sep 2026)",
                clientName: "Wingtip Online Ltd", sectionName: "Experiment (Full Service)"),
        Service(id: "2", name: "CRO Consultant", budgetName: "Wingtip - FY26 - Budget (Sep 2026)",
                clientName: "Wingtip Online Ltd", sectionName: "UXR Study"),
        Service(id: "3", name: "CRO Development", budgetName: "[NWR] NWR - Full service experimentation - Budget (Sep 2026)",
                clientName: "Northwind Retail Limited", sectionName: "Experiment (Full Service)"),
        Service(id: "4", name: "CRO Development", budgetName: "[TSP] Tailspin Sports - Full service experimentation - Budget (Sep 2026)",
                clientName: "Tailspin Sports Online.com B.V", sectionName: "Experiment (Full Service)"),
        Service(id: "5", name: "Wingtip research", budgetName: "Internal", clientName: "Acme Agency"),
    ]

    func ids(_ query: String, codes: [String: String] = [:]) -> [String] {
        ServiceSearch.filter(services, query: query, codes: codes).map(\.id)
    }

    func testClientName() {
        XCTAssertEqual(ids("wingtip"), ["1", "2", "5"], "the client's services come before a service that only mentions it")
        XCTAssertEqual(ids("northwind"), ["3"])
        XCTAssertEqual(ids("tailspin"), ["4"])
    }

    func testClientCodes() {
        XCTAssertEqual(ids("wt", codes: ["wt": "Wingtip Online Ltd"]), ["1", "2"])
        XCTAssertEqual(ids("nwr"), ["3"])
        XCTAssertEqual(ids("tsp dev"), ["4"])
    }

    func testSectionAndServiceWords() {
        XCTAssertEqual(ids("wingtip uxr"), ["2"])
        XCTAssertEqual(ids("development experiment northwind"), ["3"])
        XCTAssertEqual(ids("nothing like this"), [])
    }

    func testGroupsSortedByShortClientThenBudget() {
        let groups = ServiceSearch.groups(services)
        XCTAssertEqual(groups.map(\.title), ["Acme Agency", "Northwind Retail", "Tailspin Sports Online.com", "Wingtip Online"])
        XCTAssertEqual(groups.last?.services.map(\.id), ["1", "2"])
        XCTAssertEqual(groups.last?.budgets.count, 1)
    }
}
