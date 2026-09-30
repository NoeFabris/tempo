import Foundation

public struct ProductiveConfig: Equatable, Sendable {
    public var token: String
    public var organizationID: String

    public init(token: String, organizationID: String) {
        self.token = token
        self.organizationID = organizationID
    }
}

public enum ProductiveError: Error, LocalizedError, Equatable {
    case notConfigured
    case unauthorized
    case rateLimited
    case offline
    /// A network error where the request may have reached Productive (for example, a timeout on a POST).
    case transport(String)
    case http(status: Int, message: String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Add your Productive token in Settings."
        case .unauthorized: return "Token not valid. Check the token and the organisation ID."
        case .rateLimited: return "Productive rate limit reached. Try again soon."
        case .offline: return "No connection to Productive."
        case .transport(let detail): return "Network error (\(detail)). Refresh to see what Productive saved."
        case .http(let status, let message): return "Productive error \(status): \(message)"
        case .decoding(let detail): return "Unexpected response from Productive (\(detail))."
        }
    }

    public var isNetwork: Bool { self == .offline }
}

/// The fields of a time entry to change. A nil field does not change.
public struct EntryChanges: Equatable, Sendable {
    public var minutes: Int?
    public var note: String?
    public var serviceID: String?
    public var day: Day?

    public init(minutes: Int? = nil, note: String? = nil, serviceID: String? = nil, day: Day? = nil) {
        self.minutes = minutes
        self.note = note
        self.serviceID = serviceID
        self.day = day
    }

    public var isEmpty: Bool { minutes == nil && note == nil && serviceID == nil && day == nil }
}

extension ProductiveAPI {
    func updateTimeEntry(id: String, minutes: Int?, note: String?) async throws -> TimeEntry {
        try await updateTimeEntry(id: id, changes: EntryChanges(minutes: minutes, note: note))
    }
}

/// Everything the app needs from Productive. `TimeStore` depends on this protocol only.
public protocol ProductiveAPI: Sendable {
    func me() async throws -> Person
    func recentTimers(personID: String) async throws -> [RunningTimer]
    func timeEntries(personID: String, from: Day, to: Day) async throws -> [TimeEntry]
    func trackableServices(personID: String) async throws -> [Service]
    func createTimeEntry(personID: String, serviceID: String, day: Day, minutes: Int, note: String) async throws -> TimeEntry
    func updateTimeEntry(id: String, changes: EntryChanges) async throws -> TimeEntry
    func deleteTimeEntry(id: String) async throws
    func startTimer(timeEntryID: String) async throws -> RunningTimer
    func stopTimer(id: String) async throws -> RunningTimer
    /// Meetings on `day` from the calendar connected in Productive. Empty when none is connected.
    func calendarEvents(personID: String, day: Day) async throws -> [CalendarEvent]
}

extension ProductiveAPI {
    public func calendarEvents(personID: String, day: Day) async throws -> [CalendarEvent] { [] }
}

public final class ProductiveClient: ProductiveAPI, @unchecked Sendable {
    public static let baseURL = URL(string: "https://api.productive.io/api/v2/")!

    private let config: ProductiveConfig
    private let session: URLSession
    private let sleep: @Sendable (TimeInterval) async -> Void

    static let serviceInclude = "deal,deal.project,deal.company,section"
    static let entryInclude = "service,service.deal,service.deal.project,service.deal.company,service.section"

    /// Ephemeral: no response cache on disk.
    public static let defaultSession = URLSession(configuration: .ephemeral)

    public init(config: ProductiveConfig, session: URLSession = ProductiveClient.defaultSession,
                sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }) {
        self.config = config
        self.session = session
        self.sleep = sleep
    }

    // MARK: - Endpoints

    public func me() async throws -> Person {
        let doc = try await send("GET", "organization_memberships", query: ["include": "person"])
        guard let person = Mapping.person(fromMemberships: doc, organizationID: config.organizationID) else {
            throw ProductiveError.decoding("no person in organization_memberships")
        }
        return person
    }

    public func recentTimers(personID: String) async throws -> [RunningTimer] {
        let doc = try await send("GET", "timers", query: [
            "filter[person_id]": personID,
            "sort": "-started_at",
            "page[size]": "5",
            "include": "time_entry," + Self.entryInclude.split(separator: ",").map { "time_entry.\($0)" }.joined(separator: ","),
        ])
        let index = ResourceIndex(doc.data + doc.included)
        return doc.data.compactMap { Mapping.timer($0, index) }
    }

    public func timeEntries(personID: String, from: Day, to: Day) async throws -> [TimeEntry] {
        // `after` / `before` may be exclusive, so ask for one extra day each side and filter here.
        let docs = try await sendAllPages("time_entries", query: [
            "filter[person_id]": personID,
            "filter[after]": from.adding(days: -1).iso,
            "filter[before]": to.adding(days: 1).iso,
            "include": Self.entryInclude,
        ])
        return docs.flatMap { doc -> [TimeEntry] in
            let index = ResourceIndex(doc.data + doc.included)
            return doc.data.compactMap { Mapping.timeEntry($0, index) }
        }
        .filter { $0.day >= from && $0.day <= to }
    }

    /// Services the person can track on today. Without the budget and date filters, Productive returns
    /// every service of the organisation (tens of thousands, most in closed budgets).
    public func trackableServices(personID: String) async throws -> [Service] {
        let today = Day(Date()).iso
        let docs = try await sendAllPages("services", query: [
            "filter[trackable_by_person_id]": personID,
            "filter[time_tracking_enabled]": "true",
            "filter[budget_status]": "1", // 1 = open
            "filter[after]": today,
            "filter[before]": today,
            "include": Self.serviceInclude,
        ])
        return docs.flatMap { doc -> [Service] in
            let index = ResourceIndex(doc.data + doc.included)
            return doc.data.map { Mapping.service($0, index) }
        }
    }

    public func createTimeEntry(personID: String, serviceID: String, day: Day, minutes: Int, note: String) async throws -> TimeEntry {
        let body: [String: Any] = ["data": [
            "type": "time_entries",
            "attributes": ["date": day.iso, "time": minutes, "note": note],
            "relationships": [
                "person": ["data": ["type": "people", "id": personID]],
                "service": ["data": ["type": "services", "id": serviceID]],
            ],
        ]]
        return try await entry(from: send("POST", "time_entries", query: ["include": Self.entryInclude], body: body))
    }

    public func updateTimeEntry(id: String, changes: EntryChanges) async throws -> TimeEntry {
        var attributes: [String: Any] = [:]
        if let minutes = changes.minutes { attributes["time"] = minutes }
        if let note = changes.note { attributes["note"] = note }
        if let day = changes.day { attributes["date"] = day.iso }
        var data: [String: Any] = ["type": "time_entries", "id": id, "attributes": attributes]
        if let serviceID = changes.serviceID {
            data["relationships"] = ["service": ["data": ["type": "services", "id": serviceID]]]
        }
        let body: [String: Any] = ["data": data]
        return try await entry(from: send("PATCH", "time_entries/\(id)", query: ["include": Self.entryInclude], body: body))
    }

    public func deleteTimeEntry(id: String) async throws {
        _ = try await send("DELETE", "time_entries/\(id)")
    }

    public func startTimer(timeEntryID: String) async throws -> RunningTimer {
        let body: [String: Any] = ["data": [
            "type": "timers",
            "attributes": [String: Any](),
            "relationships": ["time_entry": ["data": ["type": "time_entries", "id": timeEntryID]]],
        ]]
        let started = try await timer(from: send("POST", "timers", body: body))
        // Productive does not return the time_entry link in this response.
        guard started.timeEntryID.isEmpty else { return started }
        return RunningTimer(id: started.id, startedAt: started.startedAt, stoppedAt: started.stoppedAt,
                            timeEntryID: timeEntryID, entry: started.entry)
    }

    public func stopTimer(id: String) async throws -> RunningTimer {
        try await timer(from: send("PATCH", "timers/\(id)/stop"))
    }

    /// `filter[start_date]` (one day) is the only date filter this endpoint accepts.
    public func calendarEvents(personID: String, day: Day) async throws -> [CalendarEvent] {
        let doc = try await send("GET", "calendar_events", query: [
            "filter[person_id]": personID,
            "filter[start_date]": day.iso,
            "page[size]": "200",
        ])
        return doc.data.compactMap(Mapping.calendarEvent).sorted { $0.start < $1.start }
    }

    // MARK: - Transport

    private func entry(from doc: Document) throws -> TimeEntry {
        let index = ResourceIndex(doc.data + doc.included)
        guard let first = doc.data.first, let e = Mapping.timeEntry(first, index) else {
            throw ProductiveError.decoding("time entry")
        }
        return e
    }

    private func timer(from doc: Document) throws -> RunningTimer {
        let index = ResourceIndex(doc.data + doc.included)
        guard let first = doc.data.first, let t = Mapping.timer(first, index) else {
            throw ProductiveError.decoding("timer")
        }
        return t
    }

    private func sendAllPages(_ path: String, query: [String: String]) async throws -> [Document] {
        var docs: [Document] = []
        var page = 1
        repeat {
            var q = query
            q["page[size]"] = "200"
            q["page[number]"] = String(page)
            let doc = try await send("GET", path, query: q)
            docs.append(doc)
            guard let total = doc.totalPages, page < total else { break }
            page += 1
        } while page <= 20
        return docs
    }

    func makeRequest(_ method: String, _ path: String, query: [String: String], body: [String: Any]?) throws -> URLRequest {
        var comps = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("application/vnd.api+json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
        req.setValue(config.token, forHTTPHeaderField: "X-Auth-Token")
        req.setValue(config.organizationID, forHTTPHeaderField: "X-Organization-Id")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return req
    }

    private func send(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil) async throws -> Document {
        guard !config.token.isEmpty, !config.organizationID.isEmpty else { throw ProductiveError.notConfigured }
        let req = try makeRequest(method, path, query: query, body: body)

        for attempt in 0...2 {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: req)
            } catch {
                throw Self.map(error, method: method)
            }
            guard let http = response as? HTTPURLResponse else { throw ProductiveError.decoding("no HTTP response") }

            switch http.statusCode {
            case 200..<300:
                if data.isEmpty || http.statusCode == 204 { return try JSONDecoder().decode(Document.self, from: Data("{}".utf8)) }
                do { return try JSONDecoder().decode(Document.self, from: data) }
                catch { throw ProductiveError.decoding(String(describing: error).prefix(120).description) }
            case 401, 403:
                throw ProductiveError.unauthorized
            case 429 where attempt < 2:
                let wait = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 10
                await sleep(min(wait, 60))
                continue
            case 429:
                throw ProductiveError.rateLimited
            default:
                throw ProductiveError.http(status: http.statusCode, message: Self.errorMessage(data))
            }
        }
        throw ProductiveError.rateLimited
    }

    /// Only errors where the request surely did not reach Productive count as offline,
    /// because offline actions are queued and sent again.
    static func map(_ error: Error, method: String) -> ProductiveError {
        guard let urlError = error as? URLError else { return .transport(error.localizedDescription) }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
            // `networkConnectionLost` can happen after a POST was sent; only treat it as offline for reads.
            if urlError.code == .networkConnectionLost && method != "GET" { return .transport(urlError.localizedDescription) }
            return .offline
        case .timedOut where method == "GET":
            return .offline
        default:
            return .transport(urlError.localizedDescription)
        }
    }

    static func errorMessage(_ data: Data) -> String {
        struct Errors: Decodable { struct E: Decodable { let title: String?; let detail: String? }; let errors: [E]? }
        if let e = try? JSONDecoder().decode(Errors.self, from: data), let first = e.errors?.first {
            return [first.title, first.detail].compactMap { $0 }.joined(separator: ": ")
        }
        return String(data: data.prefix(200), encoding: .utf8) ?? "unknown"
    }
}
