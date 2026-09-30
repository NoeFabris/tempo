import ProductiveCore
import SwiftUI

struct MainView: View {
    @EnvironmentObject var store: TimeStore

    var body: some View {
        VStack(spacing: 0) {
            TimerHeaderView()
                .padding(.horizontal, 16)
                .padding(.top, 16)
            ReplacementBanners()
                .padding(.horizontal, 16)
            WeekHeaderView()
                .padding(.horizontal, 10)
                .padding(.top, 14)
            DayStripView()
                .padding(.horizontal, 16)
                .padding(.top, 6)
            Rectangle().fill(Brand.separator).frame(height: 1).padding(.top, 12)
            DayEntriesView()
            FooterBar()
        }
    }
}

// MARK: - Timer header

struct TimerHeaderView: View {
    @EnvironmentObject var store: TimeStore
    @EnvironmentObject var nav: Navigator

    var body: some View {
        if let service = store.runningService {
            HStack(spacing: 10) {
                Circle().fill(Brand.violet).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.name).font(Brand.font(14, .semibold)).lineLimit(1)
                    Text(service.context).font(Brand.font(11)).foregroundStyle(Brand.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(TimeFormat.hms(seconds: store.runningSeconds)).font(Brand.digits(17, .semibold))
                Button { Task { await store.stop() } } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Brand.onViolet)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Brand.violet))
                }
                .buttonStyle(.plain)
                .help("Stop the timer")
            }
            .card()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    BrandHeading(bold: "Not", italic: "tracking", size: 16)
                    Spacer()
                    Button("Start…") { nav.screen = .picker(.start) }
                        .buttonStyle(PrimaryButtonStyle())
                }
                if !quickStarts.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(quickStarts) { service in
                                Button { Task { await store.start(store.resolvedService(for: service)) } } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "play.fill").font(.system(size: 8))
                                        Text(service.name).lineLimit(1)
                                    }
                                    .font(Brand.font(12, .medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Capsule().stroke(Brand.separator))
                                }
                                .buttonStyle(.plain)
                                .help(service.context)
                            }
                        }
                        .padding(1) // Keeps the capsule strokes inside the scroll view.
                    }
                }
            }
            .card()
        }
    }

    /// The last service first, then favourites.
    private var quickStarts: [Service] {
        var list: [Service] = []
        if let last = store.lastService { list.append(last) }
        for fav in store.favourites where !list.contains(where: { $0.id == fav.serviceID }) && !store.isMissing(fav) {
            list.append(fav.service)
        }
        return list
    }
}

/// Asks once to move a favourite to the new budget when its old budget closed.
struct ReplacementBanners: View {
    @EnvironmentObject var store: TimeStore

    var body: some View {
        ForEach(store.favourites.filter { store.replacements[$0.serviceID] != nil }) { fav in
            let new = store.replacements[fav.serviceID]!
            VStack(alignment: .leading, spacing: 6) {
                (Text("Budget changed ").font(Brand.font(12, .bold)) + Text("for \(fav.serviceName)").font(Brand.italic(12)))
                Text("Use “\(new.budgetName.isEmpty ? new.context : new.budgetName)”?")
                    .font(Brand.font(11)).foregroundStyle(Brand.secondary).lineLimit(2)
                HStack {
                    Button("Use new budget") { store.acceptReplacement(for: fav) }.buttonStyle(PrimaryButtonStyle())
                    Button("Remove favourite") { store.removeFavourite(fav) }.buttonStyle(SecondaryButtonStyle())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
            .padding(.top, 8)
        }
    }
}

// MARK: - Week

struct WeekHeaderView: View {
    @EnvironmentObject var store: TimeStore

    var body: some View {
        HStack(spacing: 4) {
            IconButton(systemName: "chevron.left", help: "Previous week") { store.showWeek(offset: -1) }
            BrandHeading(
                bold: store.isCurrentWeek ? "This week" : weekLabel,
                italic: "\(TimeFormat.hm(store.weekTotal)) / \(TimeFormat.hm(store.weeklyTargetMinutes))",
                size: 14
            )
            .monospacedDigit()
            Spacer()
            if !store.isCurrentWeek {
                Button("Today") { store.showCurrentWeek() }
                    .buttonStyle(.plain)
                    .font(Brand.font(12, .semibold))
                    .foregroundStyle(Brand.violet)
            }
            IconButton(systemName: "chevron.right", help: "Next week") { store.showWeek(offset: 1) }
        }
    }

    private var weekLabel: String {
        guard let first = store.weekDays.first else { return "Week" }
        return first.date().formatted(.dateTime.day().month(.abbreviated))
    }
}

struct DayStripView: View {
    @EnvironmentObject var store: TimeStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 4) {
            ForEach(store.weekDays, id: \.self) { day in
                let selected = day == store.selectedDay
                let isToday = day == store.today
                Button { store.selectedDay = day } label: {
                    VStack(spacing: 3) {
                        Text(day.date().formatted(.dateTime.weekday(.abbreviated)))
                            .font(Brand.font(10, isToday ? .bold : .medium))
                            .foregroundStyle(labelColor(selected: selected, today: isToday))
                        Text(total(day))
                            .font(Brand.digits(12, selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Brand.onViolet : Brand.text)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Brand.violet : Brand.card))
                    .overlay(alignment: .bottom) {
                        if isToday && !selected && scheme == .light {
                            Rectangle().fill(Brand.text).frame(width: 14, height: 2).padding(.bottom, 2)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func total(_ day: Day) -> String {
        let m = store.total(on: day)
        return m == 0 ? "–" : TimeFormat.hm(m)
    }

    private func labelColor(selected: Bool, today: Bool) -> Color {
        if selected { return Brand.onViolet }
        // Mellow Yellow only on black (dark mode).
        if today && scheme == .dark { return Brand.yellow }
        return today ? Brand.text : Brand.secondary
    }
}

// MARK: - Day entries

struct DayEntriesView: View {
    @EnvironmentObject var store: TimeStore
    @EnvironmentObject var nav: Navigator

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                BrandHeading(
                    bold: store.selectedDay.date().formatted(.dateTime.weekday(.abbreviated)),
                    italic: store.selectedDay.date().formatted(.dateTime.day().month(.abbreviated)),
                    size: 14
                )
                Spacer()
                Text(TimeFormat.hm(store.total(on: store.selectedDay))).font(Brand.digits(13, .semibold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            ScrollView {
                VStack(spacing: 6) {
                    let list = store.entries(on: store.selectedDay)
                    if list.isEmpty {
                        Text(store.isLoading && store.entries.isEmpty ? "Loading…" : "No time on this day.")
                            .font(Brand.italic(12))
                            .foregroundStyle(Brand.secondary)
                            .padding(.vertical, 18)
                    }
                    ForEach(list) { entry in EntryRow(entry: entry) }
                    Button { nav.startAdd(service: store.lastService, day: store.selectedDay) } label: {
                        Label("Add entry", systemImage: "plus")
                            .font(Brand.font(12, .semibold))
                            .foregroundStyle(Brand.violet)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

struct EntryRow: View {
    @EnvironmentObject var store: TimeStore
    @EnvironmentObject var nav: Navigator
    let entry: TimeEntry
    @State private var confirmDelete = false

    private var isRunning: Bool { store.timer?.timeEntryID == entry.id }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                Task {
                    if isRunning { await store.stop() }
                    else { await store.start(store.resolvedService(for: entry.service), continuing: entry) }
                }
            } label: {
                Image(systemName: isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isRunning ? Brand.onViolet : Brand.text)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(isRunning ? Brand.violet : Color.clear))
                    .overlay(Circle().stroke(isRunning ? Color.clear : Brand.separator))
            }
            .buttonStyle(.plain)
            .help(isRunning ? "Stop" : "Continue this entry")

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.service.name).font(Brand.font(13, .semibold)).lineLimit(1)
                Text(subtitle).font(Brand.font(11)).foregroundStyle(Brand.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(TimeFormat.hm(store.liveMinutes(entry)))
                .font(Brand.digits(13, isRunning ? .bold : .medium))
                .foregroundStyle(isRunning ? Brand.violet : Brand.text)

            if entry.isPending {
                Image(systemName: "icloud.slash").font(.system(size: 10)).foregroundStyle(Brand.secondary)
                    .frame(width: 24).help("Not in Productive yet. It syncs when the connection is back.")
            } else if entry.isLocked {
                Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Brand.secondary)
                    .frame(width: 24).help("Invoiced: this entry cannot change")
            } else {
                IconButton(systemName: "pencil", help: "Edit") { nav.startEdit(entry, liveMinutes: store.liveMinutes(entry)) }
                IconButton(systemName: "trash", help: "Delete") { confirmDelete = true }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Brand.card))
        .confirmationDialog("Delete this entry?", isPresented: $confirmDelete) {
            Button("Delete \(TimeFormat.hm(store.liveMinutes(entry))) on \(entry.service.name)", role: .destructive) {
                Task { await store.deleteEntry(entry) }
            }
        }
    }

    private var subtitle: String {
        [entry.service.clientName, entry.note].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: - Footer

struct FooterBar: View {
    @EnvironmentObject var store: TimeStore
    @EnvironmentObject var nav: Navigator

    var body: some View {
        HStack(spacing: 6) {
            IconButton(systemName: "gearshape", help: "Settings") { nav.screen = .settings }
            IconButton(systemName: "arrow.clockwise", help: "Refresh") { Task { await store.refresh() } }
                .rotationEffect(.degrees(store.isLoading ? 180 : 0))
                .animation(.easeInOut(duration: 0.4), value: store.isLoading)
            if let status {
                Button { store.clearError() } label: {
                    Text("⚠︎ " + status).font(Brand.font(11)).foregroundStyle(Brand.secondary).lineLimit(1)
                }
                .buttonStyle(.plain)
                .help(store.lastError ?? status)
            }
            Spacer()
            IconButton(systemName: "power", help: "Quit Tempo") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Brand.card)
    }

    private var status: String? {
        if store.isOffline { return "Offline. Changes will sync." }
        return store.lastError
    }
}
