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
