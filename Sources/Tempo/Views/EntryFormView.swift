import ProductiveCore
import SwiftUI

/// Adds a manual entry (`entryID == nil`, values in `nav.draft`) or edits an entry.
/// The edit form reads the current entry from the store, so a stop or refresh cannot leave stale values.
struct EntryFormView: View {
    @EnvironmentObject var store: TimeStore
    @EnvironmentObject var nav: Navigator
    let entryID: String?

    @State private var editTime = ""
    @State private var editNote = ""
    /// The time text when the form loaded. The time is sent only when the user changed it.
    @State private var initialTime = ""
    @State private var message: String?
    @State private var saving = false

    private var entry: TimeEntry? { entryID.flatMap(store.entry(id:)) }
    private var isAdd: Bool { entryID == nil }
    private var service: Service? { isAdd ? nav.draft.service : entry?.service }
    private var isRunning: Bool { entry.map { store.timer?.timeEntryID == $0.id } ?? false }
    private var day: Day { entry?.day ?? store.selectedDay }
    private var time: Binding<String> { isAdd ? $nav.draft.time : $editTime }
    private var note: Binding<String> { isAdd ? $nav.draft.note : $editNote }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(bold: isAdd ? "Add" : "Edit", italic: isAdd ? "time" : "entry")

            if !isAdd && entry == nil {
                Text("This entry is no longer in Productive.")
                    .font(Brand.italic(12)).foregroundStyle(Brand.secondary).padding(.horizontal, 16)
            } else {
                form.padding(.horizontal, 16)
            }
            Spacer()
        }
        .onAppear(perform: load)
        .onChange(of: isRunning) { _, _ in load() }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            label("Service")
            Button { if isAdd { nav.screen = .picker(.add) } } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(service?.name ?? "Pick a service…").font(Brand.font(13, .semibold))
                        if let service { Text(service.context).font(Brand.font(11)).foregroundStyle(Brand.secondary) }
                    }
                    .lineLimit(1)
                    Spacer()
                    if isAdd { Image(systemName: "chevron.right").foregroundStyle(Brand.secondary) }
                }
                .card()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    label("Date")
                    Text(day.date().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                        .font(Brand.font(13)).padding(.vertical, 7)
                }
                VStack(alignment: .leading, spacing: 6) {
                    label("Time (h:mm)")
                    TextField("0:30", text: time)
                        .brandField()
                        .disabled(isRunning)
                        .onSubmit(save)
                }
                .frame(width: 110)
            }
            if isRunning {
                Text("The timer is running. Stop it to change the time.")
                    .font(Brand.italic(11)).foregroundStyle(Brand.secondary)
            }
            if entry?.isLocked == true {
                Text("This entry is approved or invoiced. It cannot change.")
                    .font(Brand.italic(11)).foregroundStyle(Brand.secondary)
            }

            label("Note")
            TextField("What did you do?", text: note, axis: .vertical)
                .lineLimit(3...5)
                .brandField()

            if let message {
                Text(message).font(Brand.font(11)).foregroundStyle(Brand.secondary)
            }

            HStack {
                Button(saving ? "Saving…" : "Save", action: save)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(saving || service == nil || entry?.isLocked == true)
                    .keyboardShortcut(.defaultAction)
                Button("Cancel") { nav.screen = .main }.buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(Brand.font(11, .semibold)).foregroundStyle(Brand.secondary)
    }

    /// Loads the edit fields from the current entry. Keeps a changed note.
    private func load() {
        guard let entry else { return }
        let current = TimeFormat.hm(store.liveMinutes(entry))
        if editTime.isEmpty || editTime == initialTime { editTime = current }
        initialTime = current
        if editNote.isEmpty { editNote = entry.note }
    }

    private func save() {
        guard let service else { return }
        let text = time.wrappedValue
        let timeChanged = isAdd || text != initialTime
        var minutes: Int?
        if timeChanged {
            guard let parsed = TimeFormat.parseMinutes(text.isEmpty ? "0" : text), parsed <= 24 * 60 else {
                message = "Use h:mm, for example 1:30."
                return
            }
            minutes = parsed
        }
        saving = true
        Task {
            let ok: Bool
            if let entry {
                ok = await store.updateEntry(entry, minutes: minutes, note: note.wrappedValue)
            } else {
                ok = await store.addEntry(service: service, day: day, minutes: minutes ?? 0, note: note.wrappedValue)
            }
            saving = false
            if ok {
                if isAdd { nav.draft = .init() }
                nav.screen = .main
            } else {
                message = store.lastError ?? "Could not save."
            }
        }
    }
}
