import ProductiveCore
import SwiftUI

/// Adds a manual entry (`entry == nil`) or edits an entry.
struct EntryFormView: View {
    @EnvironmentObject var store: TimeStore
    @EnvironmentObject var nav: Navigator
    let entry: TimeEntry?
    let service: Service?

    @State private var time = ""
    @State private var note = ""
    @State private var message: String?
    @State private var saving = false

    private var isRunning: Bool { entry.map { store.timer?.timeEntryID == $0.id } ?? false }
    private var day: Day { entry?.day ?? store.selectedDay }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(bold: entry == nil ? "Add" : "Edit", italic: entry == nil ? "time" : "entry")

            VStack(alignment: .leading, spacing: 12) {
                label("Service")
                Button { if entry == nil { nav.screen = .picker(.add) } } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(service?.name ?? "Pick a service…").font(Brand.font(13, .semibold))
                            if let service { Text(service.context).font(Brand.font(11)).foregroundStyle(Brand.secondary) }
                        }
                        .lineLimit(1)
                        Spacer()
                        if entry == nil { Image(systemName: "chevron.right").foregroundStyle(Brand.secondary) }
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
                        TextField("0:30", text: $time)
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

                label("Note")
                TextField("What did you do?", text: $note, axis: .vertical)
                    .lineLimit(3...5)
                    .brandField()

                if let message {
                    Text(message).font(Brand.font(11)).foregroundStyle(Brand.secondary)
                }

                HStack {
                    Button(saving ? "Saving…" : "Save", action: save)
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(saving || service == nil)
                        .keyboardShortcut(.defaultAction)
                    Button("Cancel") { nav.screen = .main }.buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            Spacer()
        }
        .onAppear {
            if let entry {
                time = TimeFormat.hm(store.liveMinutes(entry))
                note = entry.note
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(Brand.font(11, .semibold)).foregroundStyle(Brand.secondary)
    }

    private func save() {
        guard let service else { return }
        let minutes = TimeFormat.parseMinutes(time.isEmpty ? "0" : time)
        guard let minutes, minutes <= 24 * 60 else {
            message = "Use h:mm, for example 1:30."
            return
        }
        saving = true
        Task {
            let ok: Bool
            if let entry {
                ok = await store.updateEntry(entry, minutes: minutes, note: note)
            } else {
                ok = await store.addEntry(service: service, day: day, minutes: minutes, note: note)
            }
            saving = false
            if ok { nav.screen = .main } else { message = store.lastError ?? "Could not save." }
        }
    }
}
