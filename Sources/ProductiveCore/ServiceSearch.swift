import Foundation

public struct BudgetGroup: Sendable {
    public let name: String
    public let services: [Service]
}

public struct ClientGroup: Identifiable, Sendable {
    public let clientName: String
    public let title: String
    public let budgets: [BudgetGroup]
    public var id: String { clientName }
    public var services: [Service] { budgets.flatMap(\.services) }
}

/// Grouping and search for the service picker.
public enum ServiceSearch {
    /// Groups by client, then by budget, keeping the input order inside a client.
    /// Sorted by client name, unless `keepOrder` (search results are already ranked).
    public static func groups(_ services: [Service], keepOrder: Bool = false) -> [ClientGroup] {
        var order: [String] = []
        var byClient: [String: [Service]] = [:]
        for s in services {
            if byClient[s.clientName] == nil { order.append(s.clientName) }
            byClient[s.clientName, default: []].append(s)
        }
        let groups = order.map { client -> ClientGroup in
            let list = byClient[client]!
            var budgetOrder: [String] = []
            var byBudget: [String: [Service]] = [:]
            for s in list {
                if byBudget[s.budgetName] == nil { budgetOrder.append(s.budgetName) }
                byBudget[s.budgetName, default: []].append(s)
            }
            let title = list[0].shortClientName.isEmpty ? (client.isEmpty ? "Other" : client) : list[0].shortClientName
            return ClientGroup(clientName: client, title: title,
                               budgets: budgetOrder.map { BudgetGroup(name: $0, services: byBudget[$0]!) })
        }
        return keepOrder ? groups : groups.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Every word of the query must match. Services of clients whose name or code matches come first.
    public static func filter(_ services: [Service], query: String, codes: [String: String]) -> [Service] {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return services }
        var codesByClient: [String: [String]] = [:]
        for (code, client) in codes { codesByClient[client, default: []].append(code) }

        let matches = services.filter { s in
            let hay = ([s.clientName, s.projectName, s.budgetName, s.section, s.name] + (codesByClient[s.clientName] ?? []))
                .joined(separator: " ").lowercased()
            return terms.allSatisfy { hay.contains($0) }
        }
        let first = terms[0]
        func clientHit(_ s: Service) -> Bool {
            s.shortClientName.lowercased().hasPrefix(first) || s.clientName.lowercased().contains(first)
                || (codesByClient[s.clientName] ?? []).contains(first)
                || s.budgetName.lowercased().contains("[\(first)]")
        }
        return matches.filter(clientHit) + matches.filter { !clientHit($0) }
    }
}
