import Foundation

public enum FavouriteResolution: Equatable, Sendable {
    /// The stored service is still trackable.
    case current(Service)
    /// The stored service closed; this open service has the same label (for example, next month's budget).
    case replacement(Service)
    /// No trackable service matches.
    case missing
}

public enum FavouriteMatcher {
    public static func resolve(_ fav: Favourite, in services: [Service]) -> FavouriteResolution {
        if let same = services.first(where: { $0.id == fav.serviceID }) { return .current(same) }

        let byLabel = services.filter {
            same($0.clientName, fav.clientName) && same($0.projectName, fav.projectName) && same($0.name, fav.serviceName)
        }
        let candidates = byLabel.isEmpty
            ? services.filter { same($0.clientName, fav.clientName) && same($0.name, fav.serviceName) }
            : byLabel
        // Newer budgets have higher ids.
        guard let best = candidates.max(by: { (Int($0.id) ?? 0) < (Int($1.id) ?? 0) }) else { return .missing }
        return .replacement(best)
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }
}
