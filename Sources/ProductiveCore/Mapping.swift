import Foundation

/// Maps JSON:API resources to domain models.
public enum Mapping {
    public static func service(_ r: Resource, _ index: ResourceIndex) -> Service {
        let deal = index.resource(r.related("deal"))
        let project = index.resource(deal?.related("project")) ?? index.resource(r.related("project"))
        let company = index.resource(deal?.related("company")) ?? index.resource(project?.related("company"))
        return Service(
            id: r.id,
            name: r[attribute: "name"]?.string ?? "Service \(r.id)",
            budgetName: deal?[attribute: "name"]?.string ?? "",
            projectName: project?[attribute: "name"]?.string ?? "",
            clientName: company?[attribute: "name"]?.string ?? ""
        )
    }

    public static func timeEntry(_ r: Resource, _ index: ResourceIndex) -> TimeEntry? {
        guard let dayString = r[attribute: "date"]?.string, let day = Day(iso: dayString) else { return nil }
        let serviceID = r.related("service")
        let service = index.resource(serviceID).map { Mapping.service($0, index) }
            ?? Service(id: serviceID?.id ?? "", name: "Unknown service")
        let locked = (r[attribute: "approved"]?.bool ?? false) || (r[attribute: "invoiced"]?.bool ?? false)
        return TimeEntry(
            id: r.id,
            day: day,
            minutes: r[attribute: "time"]?.int ?? 0,
            note: plainText(r[attribute: "note"]?.string ?? ""),
            service: service,
            isLocked: locked
        )
    }

    public static func timer(_ r: Resource, _ index: ResourceIndex) -> RunningTimer? {
        guard let started = r[attribute: "started_at"]?.string.flatMap(parseDate) else { return nil }
        let entryID = r.related("time_entry")?.id ?? r[attribute: "time_entry_id"]?.string ?? ""
        let entry = index.resource(ResourceIdentifier(type: "time_entries", id: entryID))
            .flatMap { timeEntry($0, index) }
        return RunningTimer(
            id: r.id,
            startedAt: started,
            stoppedAt: r[attribute: "stopped_at"]?.string.flatMap(parseDate),
            timeEntryID: entryID,
            entry: entry
        )
    }

    public static func person(fromMemberships doc: Document, organizationID: String) -> Person? {
        let index = ResourceIndex(doc.data + doc.included)
        let membership = doc.data.first { $0.related("organization")?.id == organizationID } ?? doc.data.first
        guard let membership, let personID = membership.related("person") else { return nil }
        let person = index.resource(personID)
        let first = person?[attribute: "first_name"]?.string ?? ""
        let last = person?[attribute: "last_name"]?.string ?? ""
        let name = "\(first) \(last)".trimmingCharacters(in: .whitespaces)
        return Person(id: personID.id, name: name.isEmpty ? "Person \(personID.id)" : name)
    }

    /// Productive notes can hold HTML. The popup shows plain text.
    public static func plainText(_ html: String) -> String {
        guard html.contains("<") || html.contains("&") else { return html }
        var s = html.replacingOccurrences(of: "<br\\s*/?>|</p>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        return s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    public static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
