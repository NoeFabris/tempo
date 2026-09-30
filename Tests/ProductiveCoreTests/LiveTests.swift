import XCTest
@testable import ProductiveCore

/// Runs against the real Productive API only when PRODUCTIVE_TOKEN and PRODUCTIVE_ORG_ID are set.
/// Read-only.
final class LiveTests: XCTestCase {
    func client() throws -> (ProductiveClient, String) {
        let env = ProcessInfo.processInfo.environment
        guard let token = env["PRODUCTIVE_TOKEN"], let org = env["PRODUCTIVE_ORG_ID"], let person = env["PRODUCTIVE_PERSON_ID"] else {
            throw XCTSkip("Set PRODUCTIVE_TOKEN, PRODUCTIVE_ORG_ID and PRODUCTIVE_PERSON_ID to run live tests.")
        }
        return (ProductiveClient(config: ProductiveConfig(token: token, organizationID: org)), person)
    }

    func testLiveCalendar() async throws {
        let (api, person) = try client()
        for day in [Day(Date()), Day(Date()).adding(days: -1)] {
            let events = try await api.calendarEvents(personID: person, day: day)
            print("LIVE calendar \(day.iso): \(events.count) →", events.map { "\($0.name.prefix(12)) \($0.minutes)m loggable=\($0.isLoggable)" })
        }
    }
}
