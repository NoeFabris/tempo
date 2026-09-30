import Foundation

/// A meeting from the calendar that the user connected in Productive (Outlook or Google).
public struct CalendarEvent: Identifiable, Equatable, Sendable {
    /// Stable for one occurrence: the calendar's event id plus the start time.
    public let id: String
    public let name: String
    public let start: Date
    public let end: Date
    /// The same for every occurrence of a repeating meeting.
    public let seriesID: String?
    public let isAllDay: Bool
    /// "accepted", "declined", "tentativelyAccepted", …
    public let responseStatus: String
    /// "busy", "free", …
    public let eventType: String
    public let organizer: String

    public init(id: String, name: String, start: Date, end: Date, seriesID: String? = nil, isAllDay: Bool = false,
                responseStatus: String = "accepted", eventType: String = "busy", organizer: String = "") {
        self.id = id
        self.name = name
        self.start = start
        self.end = end
        self.seriesID = seriesID
        self.isAllDay = isAllDay
        self.responseStatus = responseStatus
        self.eventType = eventType
        self.organizer = organizer
    }

    public var minutes: Int { max(0, Int(end.timeIntervalSince(start)) / 60) }

    /// The key that the remembered service uses: the series, or the name for single meetings.
    public var seriesKey: String { seriesID ?? "name:" + name.lowercased() }

    /// A short label for events that are usually not logged, or nil.
    public var statusLabel: String? {
        if name.lowercased().hasPrefix("canceled:") || name.lowercased().hasPrefix("cancelled:") { return "Cancelled" }
        if responseStatus.lowercased() == "declined" { return "Declined" }
        if isAllDay { return "All day" }
        if eventType.lowercased() == "free" { return "Free" }
        return nil
    }

    /// Meetings that are usually logged: timed, not declined, not cancelled, not marked free.
    public var isLoggable: Bool {
        statusLabel == nil && minutes > 0
    }
}

extension Mapping {
    public static func calendarEvent(_ r: Resource) -> CalendarEvent? {
        let startTime = r[attribute: "start_time"]?.string.flatMap(parseDate)
        let endTime = r[attribute: "end_time"]?.string.flatMap(parseDate)
        let startDay = r[attribute: "start_date"]?.string.flatMap(Day.init(iso:))
        let endDay = r[attribute: "end_date"]?.string.flatMap(Day.init(iso:))
        guard let start = startTime ?? startDay.map({ Calendar.current.startOfDay(for: $0.date()) }) else { return nil }
        let end = endTime ?? endDay.map { Calendar.current.startOfDay(for: $0.date()) } ?? start
        let eventID = r[attribute: "event_id"]?.string ?? r.id
        return CalendarEvent(
            id: "\(eventID)@\(Int(start.timeIntervalSince1970))",
            name: r[attribute: "name"]?.string ?? "Meeting",
            start: start,
            end: end,
            seriesID: r[attribute: "recurring_event_id"]?.string,
            isAllDay: startTime == nil,
            responseStatus: r[attribute: "response_status"]?.string ?? "",
            eventType: r[attribute: "event_type"]?.string ?? "",
            organizer: r[attribute: "organizer_name"]?.string ?? ""
        )
    }
}
