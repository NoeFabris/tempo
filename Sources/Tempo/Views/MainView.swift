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
        if let entry = store.runningEntry {
            HStack(spacing: 10) {
                Circle().fill(Brand.violet).frame(width: 8, height: 8)
                EntryLabels(entry: entry, titleSize: 15)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                Text(TimeFormat.hms(seconds: store.runningSeconds)).font(Brand.digits(15, .semibold)).fixedSize()
                Button { Task { await store.stop() } } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Brand.onViolet)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Brand.violet))
                        .contentShape(Circle())
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
                            ForEach(quickStarts) { chip in
                                Button { Task { await chip.start(store) } } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "play.fill").font(.system(size: 8))
                                        Text(chip.title).font(Brand.font(12, .semibold))
                                        if !chip.detail.isEmpty {
                                            Text(chip.detail).font(Brand.font(12)).foregroundStyle(Brand.secondary)
                                        }
                                    }
                                    .lineLimit(1)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Capsule().stroke(Brand.separator))
                                    .contentShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .help(chip.help)
                            }
                        }
                        .padding(1) // Keeps the capsule strokes inside the scroll view.
                    }
                }
            }
            .card()
        }
    }

    /// A quick-start chip: client first, then the note (resume) or the service (favourite).
    struct Chip: Identifiable {
        let id: String
        let title: String
        let detail: String
        let help: String
        let start: @MainActor (TimeStore) async -> Void
    }

    /// The task that ▶ resumes first, then the favourites.
    private var quickStarts: [Chip] {
        var chips: [Chip] = []
        if let entry = store.resumableEntry {
            chips.append(Chip(id: "resume", title: Self.client(entry.service),
                              detail: entry.note.isEmpty ? (entry.jira?.key ?? entry.service.name) : entry.note,
                              help: "Resume: \(entry.service.name) — \(entry.service.context)") { store in
                await store.start(store.resolvedService(for: entry.service), continuing: entry)
            })
        } else if let last = store.lastService {
            chips.append(Chip(id: "last", title: Self.client(last), detail: last.name, help: last.context) { store in
                _ = await store.toggle()
            })
        }
        let lastChipService = store.resumableEntry == nil ? store.lastService?.id : nil
        for fav in store.favourites where !store.isMissing(fav) && fav.serviceID != lastChipService {
            let service = fav.service
            chips.append(Chip(id: "fav-\(fav.serviceID)", title: Self.client(service), detail: service.name,
                              help: service.context) { store in
                await store.start(store.resolvedService(for: service))
            })
        }
        return chips
    }

    static func client(_ service: Service) -> String {
        service.shortClientName.isEmpty ? service.name : service.shortClientName
    }
}

/// Client (title), then the Jira key and note, then the service. Used by the header and the rows.
struct EntryLabels: View {
    let entry: TimeEntry
    var titleSize: CGFloat = 13
    var titleColor: Color = Brand.text

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(TimerHeaderView.client(entry.service))
                .font(Brand.font(titleSize, .semibold)).foregroundStyle(titleColor).lineLimit(1)
                .help(entry.service.clientName)
            if !entry.note.isEmpty || entry.jira != nil {
                EntryDetailLine(entry: entry)
            }
            Text(entry.service.shortClientName.isEmpty ? entry.service.context : entry.service.name)
                .font(Brand.font(11)).foregroundStyle(Brand.secondary).lineLimit(1)
                .help(entry.service.budgetName)
        }
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
                    let meetings = store.meetings(on: store.selectedDay)
                    if !meetings.isEmpty {
                        SectionLabel(bold: "Calendar", italic: "")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(meetings) { MeetingRow(event: $0) }
                    }
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
        .task(id: store.selectedDay) { await store.loadCalendar(store.selectedDay) }
    }
}

/// A meeting from the connected calendar: + opens the Add form with its values filled in.
struct MeetingRow: View {
    @EnvironmentObject var store: TimeStore
    @EnvironmentObject var nav: Navigator
    let event: CalendarEvent

    var body: some View {
        let logged = store.loggedEntry(for: event)
        HStack(spacing: 10) {
            Image(systemName: logged == nil ? "calendar" : "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(logged == nil ? Brand.secondary : Brand.violet)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.name).font(Brand.font(13, .semibold)).lineLimit(1)
                Text(subtitle(logged)).font(Brand.font(11)).foregroundStyle(Brand.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            Text(TimeFormat.hm(event.minutes)).font(Brand.digits(13)).foregroundStyle(Brand.secondary).fixedSize()
            if logged == nil {
                IconButton(systemName: "plus", help: "Log this meeting", tint: Brand.violet) {
                    nav.startAdd(event: event, service: store.rememberedService(for: event))
                }
            } else {
                Color.clear.frame(width: 24, height: 24)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).stroke(Brand.separator))
        .help(event.organizer.isEmpty ? event.name : "\(event.name) — \(event.organizer)")
    }

    private func subtitle(_ logged: TimeEntry?) -> String {
        let time = "\(event.start.formatted(date: .omitted, time: .shortened))–\(event.end.formatted(date: .omitted, time: .shortened))"
        guard let logged else { return time }
        return "\(time) · logged on \(TimerHeaderView.client(logged.service))"
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
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(isRunning ? Brand.violet : Color.clear))
                    .overlay(Circle().stroke(isRunning ? Color.clear : Brand.separator))
                    .contentShape(Circle()) // The transparent inside must take clicks too.
            }
            .buttonStyle(.plain)
            .help(isRunning ? "Stop" : "Continue this entry")

            EntryLabels(entry: entry)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            Spacer(minLength: 4)
            Text(TimeFormat.hm(store.liveMinutes(entry)))
                .font(Brand.digits(13, isRunning ? .bold : .medium))
                .foregroundStyle(isRunning ? Brand.violet : Brand.text)
                .fixedSize()

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

}

/// The note, then the Jira key as a link. Without a note, the Jira summary shows instead.
struct EntryDetailLine: View {
    let entry: TimeEntry

    var body: some View {
        HStack(spacing: 6) {
            if let jira = entry.jira {
                if let url = jira.url {
                    Link(destination: url) { jiraLabel(jira) }
                        .help("Open \(jira.key) in Jira: \(jira.summary)")
                } else {
                    jiraLabel(jira).help(jira.summary)
                }
            }
            Text(entry.note.isEmpty ? (entry.jira?.summary ?? "") : entry.note)
                .font(Brand.font(11))
                .foregroundStyle(Brand.text)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func jiraLabel(_ jira: JiraLink) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "arrow.up.right.square").font(.system(size: 9, weight: .semibold))
            Text(jira.key).font(Brand.font(11, .semibold))
        }
        .foregroundStyle(Brand.violet)
        .fixedSize()
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
