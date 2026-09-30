import ProductiveCore
import SwiftUI

/// Adds a manual entry (`entryID == nil`) or edits an entry. The values live in `nav.draft`,
/// so they survive a trip to the service picker. An edit sends only the fields that changed.
struct EntryFormView: View {
    @EnvironmentObject var store: TimeStore
    @EnvironmentObject var nav: Navigator
    let entryID: String?

    @State private var message: String?
    @State private var saving = false

    /// The current entry from the store (a refresh or a stop can change it while the form is open).
    private var entry: TimeEntry? { entryID.flatMap(store.entry(id:)) }
    private var isAdd: Bool { entryID == nil }
    private var isRunning: Bool { entry.map { store.timer?.timeEntryID == $0.id } ?? false }
    private var isLocked: Bool { entry?.isLocked == true }
    private var day: Day { nav.draft.day ?? entry?.day ?? store.selectedDay }

    private var dateBinding: Binding<Date> {
        Binding(get: { day.date() }, set: { nav.draft.day = Day($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(bold: isAdd ? "Add" : "Edit", italic: isAdd ? (nav.draft.event == nil ? "time" : "meeting") : "entry")

            if !isAdd && entry == nil {
                Text("This entry is no longer in Productive.")
                    .font(Brand.italic(12)).foregroundStyle(Brand.secondary).padding(.horizontal, 16)
            } else {
                form.padding(.horizontal, 16)
            }
            Spacer()
        }
        .onChange(of: isRunning) { _, _ in reloadTimeAfterStop() }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            label("Service")
            Button { nav.screen = .picker(.form(entryID)) } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(nav.draft.service?.name ?? "Pick a service…").font(Brand.font(13, .semibold))
                        if let service = nav.draft.service {
                            Text(service.context).font(Brand.font(11)).foregroundStyle(Brand.secondary)
                        }
                    }
                    .lineLimit(1)
                    Spacer()
                    if !isRunning && !isLocked { Image(systemName: "chevron.right").foregroundStyle(Brand.secondary) }
                }
                .card()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isRunning || isLocked)

            if let entry, entry.jira != nil {
                EntryDetailLine(entry: entry)
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    label("Date")
                    DatePicker("", selection: dateBinding, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .font(Brand.font(13))
                        .disabled(isRunning || isLocked)
                        .padding(.vertical, 3)
                }
                VStack(alignment: .leading, spacing: 6) {
                    label("Time (h:mm)")
                    TextField("0:30", text: $nav.draft.time)
                        .brandField()
                        .disabled(isRunning || isLocked)
                        .onSubmit(save)
                }
                .frame(width: 110)
            }
            if isRunning {
                Text("The timer is running. Stop it to change the service, date or time.")
                    .font(Brand.italic(11)).foregroundStyle(Brand.secondary)
            }
            if isLocked {
                Text("This entry is invoiced. It cannot change.")
                    .font(Brand.italic(11)).foregroundStyle(Brand.secondary)
            }

            label("Note")
            TextField("What did you do?", text: $nav.draft.note, axis: .vertical)
                .lineLimit(3...5)
                .brandField()
                .disabled(isLocked)

            if let message {
                Text(message).font(Brand.font(11)).foregroundStyle(Brand.secondary)
            }

            HStack {
                Button(saving ? "Saving…" : "Save", action: save)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(saving || nav.draft.service == nil || isLocked)
                    .keyboardShortcut(.defaultAction)
                Button("Cancel") { nav.screen = .main }.buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(Brand.font(11, .semibold)).foregroundStyle(Brand.secondary)
    }

    /// When the timer stops while the form is open, show the final time (unless the user typed one).
    private func reloadTimeAfterStop() {
        guard let entry, nav.draft.time == nav.draft.originalTime else { return }
        let current = TimeFormat.hm(store.liveMinutes(entry))
        nav.draft.time = current
        nav.draft.originalTime = current
    }

    private func save() {
        guard let service = nav.draft.service else { return }
        let draft = nav.draft
        var minutes: Int?
        if isAdd || draft.time != draft.originalTime {
            guard let parsed = TimeFormat.parseMinutes(draft.time.isEmpty ? "0" : draft.time), parsed <= 24 * 60 else {
                message = "Use h:mm, for example 1:30."
                return
            }
            minutes = parsed
        }
        saving = true
        Task {
            let ok: Bool
            if let entry {
                let original = draft.original ?? entry
                ok = await store.updateEntry(entry, changes: EntryChanges(
                    minutes: minutes,
                    note: draft.note != original.note ? draft.note : nil,
                    serviceID: service.id != original.service.id ? service.id : nil,
                    day: day != original.day ? day : nil
                ))
            } else {
                ok = await store.addEntry(service: service, day: day, minutes: minutes ?? 0, note: draft.note, event: draft.event)
            }
            saving = false
            if ok {
                nav.draft = .init()
                nav.screen = .main
            } else {
                message = store.lastError ?? "Could not save."
            }
        }
    }
}
