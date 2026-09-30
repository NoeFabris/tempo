import ProductiveCore
import SwiftUI

/// Favourites first, then a search in all trackable services, grouped by client.
struct ServicePickerView: View {
    @EnvironmentObject var store: TimeStore
    @EnvironmentObject var nav: Navigator
    let mode: Navigator.PickerMode
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(bold: mode == .start ? "Start" : "Pick", italic: mode == .start ? "a timer" : "a service",
                         back: mode == .start ? .main : .add(nil))

            HStack(spacing: 6) {
                TextField("Search client, project or service", text: $query)
                    .focused($searchFocused)
                    .brandField()
                IconButton(systemName: "arrow.clockwise", help: "Reload services") {
                    Task { await store.refreshServices() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if query.isEmpty && !store.favourites.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            SectionLabel(bold: "Favourites", italic: "")
                            ForEach(store.favourites) { fav in
                                if store.isMissing(fav) {
                                    closedRow(fav)
                                } else {
                                    row(store.replacements[fav.serviceID] ?? store.resolvedService(for: fav.service))
                                }
                            }
                        }
                    }
                    if store.services.isEmpty {
                        Text(store.isLoading ? "Loading services…" : "No services found. Press reload.")
                            .font(Brand.italic(12)).foregroundStyle(Brand.secondary).padding(.vertical, 12)
                    }
                    ForEach(groups, id: \.client) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            SectionLabel(bold: group.client.isEmpty ? "Other" : group.client, italic: "")
                            ForEach(group.services) { row($0) }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .onAppear {
            searchFocused = true
            if store.services.isEmpty { Task { await store.refreshServices() } }
        }
    }

    private var groups: [(client: String, services: [Service])] {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        let matches = store.services.filter { s in
            let hay = "\(s.clientName) \(s.projectName) \(s.budgetName) \(s.name)".lowercased()
            return terms.allSatisfy { hay.contains($0) }
        }
        var order: [String] = []
        var byClient: [String: [Service]] = [:]
        for s in matches {
            if byClient[s.clientName] == nil { order.append(s.clientName) }
            byClient[s.clientName, default: []].append(s)
        }
        return order.map { ($0, byClient[$0]!) }
    }

    private func row(_ service: Service) -> some View {
        HStack(spacing: 8) {
            Button { choose(service) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.name).font(Brand.font(13, .semibold)).lineLimit(1)
                    Text(service.budgetName.isEmpty ? service.projectName : service.budgetName)
                        .font(Brand.font(11)).foregroundStyle(Brand.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(service.budgetName)

            let fav = store.isFavourite(service)
            IconButton(systemName: fav ? "star.fill" : "star", help: fav ? "Remove favourite" : "Add to favourites",
                       tint: fav ? Brand.violet : Brand.secondary) {
                store.toggleFavourite(service)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Brand.card))
    }

    /// A favourite with no open budget: it cannot start.
    private func closedRow(_ fav: Favourite) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(fav.serviceName).font(Brand.font(13, .semibold)).foregroundStyle(Brand.secondary).lineLimit(1)
                Text("No open budget. \(fav.clientName)").font(Brand.italic(11)).foregroundStyle(Brand.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            IconButton(systemName: "xmark", help: "Remove favourite") { store.removeFavourite(fav) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).stroke(Brand.separator))
    }

    private func choose(_ service: Service) {
        switch mode {
        case .start:
            nav.screen = .main
            Task { await store.start(service) }
        case .add:
            nav.screen = .add(service)
        }
    }
}

struct SectionLabel: View {
    let bold: String
    let italic: String

    var body: some View {
        (Text(bold).font(Brand.font(11, .bold)) + Text(italic.isEmpty ? "" : " " + italic).font(Brand.italic(11)))
            .foregroundStyle(Brand.secondary)
            .textCase(.uppercase)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }
}
