import ProductiveCore
import SwiftUI

/// Picks a service. Without a search: Recent, Favourites, then one collapsed row per client.
/// With a search: the matching services, grouped by client. The search looks at the client,
/// client codes (from Jira keys and "[NWR]"-style budget prefixes), budget, section and service.
struct ServicePickerView: View {
    @EnvironmentObject var store: TimeStore
    @EnvironmentObject var nav: Navigator
    let mode: Navigator.PickerMode
    @State private var query = ""
    /// Optional note for the new timer (start mode only).
    @State private var note = ""
    @State private var expanded: Set<String> = []
    @FocusState private var searchFocused: Bool
    @FocusState private var noteFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(bold: mode == .start ? "Start" : "Pick", italic: mode == .start ? "a timer" : "a service",
                         back: backScreen)

            HStack(spacing: 6) {
                TextField("Search client, code, budget or service", text: $query)
                    .focused($searchFocused)
                    .brandField()
                RefreshButton(help: "Reload services", isRefreshing: store.isLoadingServices) {
                    Task { await store.refreshServices() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, mode == .start ? 6 : 8)

            if mode == .start {
                TextField(store.noteRequired == nil ? "Note (optional)" : "Note (required)", text: $note)
                    .focused($noteFocused)
                    .brandField()
                    .padding(.horizontal, 16)
                    .padding(.trailing, 30)
                    .padding(.bottom, store.noteRequired == nil ? 8 : 4)
                if let service = store.noteRequired {
                    Text("Productive needs a note for \(TimerHeaderView.client(service)) · \(service.name). Type it, then pick the service again.")
                        .font(Brand.italic(11)).foregroundStyle(Brand.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if store.services.isEmpty {
                        Text(store.isLoading ? "Loading services…" : "No services found. Press reload.")
                            .font(Brand.italic(12)).foregroundStyle(Brand.secondary).padding(.vertical, 12)
                    } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        browse
                    } else {
                        results
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .onAppear {
            if store.noteRequired != nil && mode == .start { noteFocused = true } else { searchFocused = true }
            if store.services.isEmpty { Task { await store.refreshServices() } }
        }
        .onChange(of: store.noteRequired) { _, service in if service != nil && mode == .start { noteFocused = true } }
        .onDisappear { if mode == .start && nav.screen != .picker(.start) { store.clearNoteRequired() } }
    }

    // MARK: Browse (no search)

    @ViewBuilder private var browse: some View {
        let recent = Array(store.recentServices.prefix(2))
        if !recent.isEmpty {
            block("Recent") { ForEach(recent) { row($0, showClient: true) } }
        }
        if !store.favourites.isEmpty {
            block("Favourites") {
                ForEach(store.favourites) { fav in
                    if store.isMissing(fav) {
                        closedRow(fav)
                    } else {
                        row(store.replacements[fav.serviceID] ?? store.resolvedService(for: fav.service), showClient: true)
                    }
                }
            }
        }
        block("All clients") {
            ForEach(ServiceSearch.groups(store.services)) { group in
                clientHeader(group, collapsible: true)
                if expanded.contains(group.id) { groupBody(group) }
            }
        }
    }

    // MARK: Search

    @ViewBuilder private var results: some View {
        let groups = ServiceSearch.groups(ServiceSearch.filter(store.services, query: query, codes: store.clientCodes), keepOrder: true)
        if groups.isEmpty {
            Text("No service matches “\(query)”.")
                .font(Brand.italic(12)).foregroundStyle(Brand.secondary).padding(.vertical, 12)
        }
        ForEach(groups) { group in
            VStack(alignment: .leading, spacing: 4) {
                clientHeader(group, collapsible: false)
                groupBody(group)
            }
        }
    }

    // MARK: Pieces

    private func block<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(bold: title, italic: "")
            content()
        }
    }

    private func clientHeader(_ group: ClientGroup, collapsible: Bool) -> some View {
        Button {
            guard collapsible else { return }
            if expanded.contains(group.id) { expanded.remove(group.id) } else { expanded.insert(group.id) }
        } label: {
            HStack(spacing: 6) {
                if collapsible {
                    Image(systemName: expanded.contains(group.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(Brand.secondary).frame(width: 10)
                }
                Text(group.title).font(Brand.font(13, .bold)).lineLimit(1)
                Spacer()
                Text("\(group.services.count)").font(Brand.digits(11)).foregroundStyle(Brand.secondary)
            }
            .padding(.vertical, collapsible ? 6 : 4)
            .padding(.top, collapsible ? 0 : 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(group.clientName)
    }

    /// The services of one client, under a small label per budget.
    @ViewBuilder private func groupBody(_ group: ClientGroup) -> some View {
        ForEach(group.budgets, id: \.name) { budget in
            if !budget.name.isEmpty {
                Text(budget.name)
                    .font(Brand.italic(11)).foregroundStyle(Brand.secondary)
                    .lineLimit(2)
                    .padding(.leading, 16).padding(.top, 4)
            }
            ForEach(budget.services) { row($0, showClient: false).padding(.leading, 16) }
        }
    }

    /// `showClient`: the client is the title (mixed lists). Otherwise the service is the title.
    private func row(_ service: Service, showClient: Bool) -> some View {
        HStack(spacing: 8) {
            Button { choose(service) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    if showClient {
                        Text(TimerHeaderView.client(service)).font(Brand.font(13, .semibold)).lineLimit(1)
                        HStack(spacing: 6) {
                            Text([service.name, service.section].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(Brand.font(11)).foregroundStyle(Brand.secondary).lineLimit(1)
                            BudgetMonthTag(service: service, day: store.today)
                        }
                    } else {
                        HStack(spacing: 6) {
                            Text(service.name).font(Brand.font(13, .semibold)).lineLimit(1)
                            BudgetMonthTag(service: service, day: store.today)
                        }
                        if !service.section.isEmpty {
                            Text(service.section).font(Brand.font(11)).foregroundStyle(Brand.secondary).lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help([service.clientName, service.budgetName, service.section, service.name].filter { !$0.isEmpty }.joined(separator: "\n"))

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
                Text(TimerHeaderView.client(fav.service)).font(Brand.font(13, .semibold)).foregroundStyle(Brand.secondary).lineLimit(1)
                Text("\(fav.serviceName) · no open budget").font(Brand.italic(11)).foregroundStyle(Brand.secondary).lineLimit(1)
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
            let note = note.trimmingCharacters(in: .whitespaces)
            Task { await store.start(service, note: note) }
        case .form:
            nav.draft.service = service
            nav.screen = backScreen
        }
    }

    private var backScreen: Navigator.Screen {
        switch mode {
        case .start: return .main
        case .form(nil): return .add
        case .form(let id?): return .edit(id)
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
