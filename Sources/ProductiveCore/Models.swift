import Foundation

/// A calendar day in the user's time zone, stored as `yyyy-MM-dd`.
public struct Day: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let iso: String

    public init?(iso: String) {
        guard Day.parse(iso) != nil else { return nil }
        self.iso = iso
    }

    public init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        iso = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    public func date(calendar: Calendar = .current) -> Date {
        let (y, m, d) = Day.parse(iso)!
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    public func adding(days: Int, calendar: Calendar = .current) -> Day {
        Day(calendar.date(byAdding: .day, value: days, to: date(calendar: calendar))!, calendar: calendar)
    }

    public static func < (a: Day, b: Day) -> Bool { a.iso < b.iso }
    public var description: String { iso }

    private static func parse(_ s: String) -> (Int, Int, Int)? {
        let parts = s.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        return (y, m, d)
    }
}

public struct Person: Equatable, Codable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct Service: Identifiable, Equatable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let budgetName: String
    public let projectName: String
    public let clientName: String
    /// The budget section, for example "Experiment (Full Service)". Optional for stored data from older versions.
    public let sectionName: String?
    /// The order of the service in its budget.
    public let position: Int?
    /// The last day of the budget, when it has one (monthly budgets do). Optional for stored data from older versions.
    public let budgetEnd: Day?
    /// The budget refuses entries without a note (Productive's time entry requirements). Nil when unknown.
    public let requiresNote: Bool?

    public init(id: String, name: String, budgetName: String = "", projectName: String = "", clientName: String = "",
                sectionName: String? = nil, position: Int? = nil, budgetEnd: Day? = nil, requiresNote: Bool? = nil) {
        self.id = id
        self.name = name
        self.budgetName = budgetName
        self.projectName = projectName
        self.clientName = clientName
        self.sectionName = sectionName
        self.position = position
        self.budgetEnd = budgetEnd
        self.requiresNote = requiresNote
    }

    public var section: String { sectionName ?? "" }

    /// True when the budget ended before the month of `day`: a September budget seen in October.
    public func budgetEndedBeforeMonth(of day: Day) -> Bool {
        guard let budgetEnd else { return false }
        return budgetEnd.iso.prefix(7) < day.iso.prefix(7) // "2026-09" < "2026-10"
    }

    /// The client without its legal suffix: "Wingtip Online Ltd" → "Wingtip Online".
    public var shortClientName: String {
        var name = clientName.trimmingCharacters(in: .whitespaces)
        let suffixes = [" limited", " ltd.", " ltd", " b.v.", " b.v", " bv", " inc.", " inc", " llc", " plc",
                        " gmbh", " s.l.", " sl", " s.a.", " sa", " pty", " co."]
        var changed = true
        while changed {
            changed = false
            for suffix in suffixes where name.lowercased().hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count)).trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
                changed = true
            }
        }
        return name
    }

    /// "Client · Project" (or the budget when no project is known).
    public var context: String {
        [clientName, projectName.isEmpty ? budgetName : projectName]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// The Jira issue that an entry was tracked on (Productive's Jira integration).
public struct JiraLink: Equatable, Sendable {
    public let key: String
    public let summary: String
    public let url: URL?

    public init(key: String, summary: String, url: URL?) {
        self.key = key
        self.summary = summary
        self.url = url
    }

    /// The experiment code in the summary: "WT E97 Checkout Test 1" → "E97".
    public var baseExperimentCode: String? {
        guard let range = summary.range(of: #"\bE\d{1,4}\b"#, options: .regularExpression) else { return nil }
        return String(summary[range])
    }

    /// The note for the entry: the code, plus "QA" when the summary has the word QA.
    /// "NWR E83 QA - Sticky Gallery" → "E83 QA"; "WT E97 Checkout Test 1" → "E97".
    public var experimentCode: String? {
        guard let code = baseExperimentCode else { return nil }
        let isQA = summary.range(of: #"\bQA\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        return isQA ? code + " QA" : code
    }
}

public struct TimeEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public var day: Day
    /// Tracked minutes, as stored by Productive.
    public var minutes: Int
    public var note: String
    public var service: Service
    /// Invoiced entries cannot change.
    public var isLocked: Bool
    public var jira: JiraLink?
    /// The last time the entry got time: its creation, or the last start or stop of its timer.
    /// Orders the day list, most recent first.
    public var trackedAt: Date?

    public init(id: String, day: Day, minutes: Int, note: String, service: Service, isLocked: Bool = false,
                jira: JiraLink? = nil, trackedAt: Date? = nil) {
        self.id = id
        self.day = day
        self.minutes = minutes
        self.note = note
        self.service = service
        self.isLocked = isLocked
        self.jira = jira
        self.trackedAt = trackedAt
    }

    /// A local placeholder for a start that has not reached Productive yet.
    public var isPending: Bool { id.hasPrefix("pending-") }
}

public struct RunningTimer: Identifiable, Equatable, Sendable {
    public let id: String
    public let startedAt: Date
    public let stoppedAt: Date?
    public let timeEntryID: String
    /// The timer's entry, when the API included it.
    public var entry: TimeEntry?

    public init(id: String, startedAt: Date, stoppedAt: Date? = nil, timeEntryID: String, entry: TimeEntry? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.stoppedAt = stoppedAt
        self.timeEntryID = timeEntryID
        self.entry = entry
    }

    public var isRunning: Bool { stoppedAt == nil }
}

/// The entry that the last timer ran on, so ▶ can resume the same task.
public struct LastEntry: Equatable, Codable, Sendable {
    public let entryID: String
    public let day: Day
    public let serviceID: String
    public let note: String

    public init(entryID: String, day: Day, serviceID: String, note: String) {
        self.entryID = entryID
        self.day = day
        self.serviceID = serviceID
        self.note = note
    }
}

public struct Favourite: Identifiable, Equatable, Codable, Sendable {
    public var serviceID: String
    public var serviceName: String
    public var budgetName: String
    public var projectName: String
    public var clientName: String
    public var sectionName: String?

    public var id: String { serviceID }

    public init(service: Service) {
        serviceID = service.id
        serviceName = service.name
        budgetName = service.budgetName
        projectName = service.projectName
        clientName = service.clientName
        sectionName = service.sectionName
    }

    public var service: Service {
        Service(id: serviceID, name: serviceName, budgetName: budgetName, projectName: projectName, clientName: clientName,
                sectionName: sectionName)
    }
}
