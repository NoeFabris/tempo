import ProductiveCore
import ServiceManagement
import SwiftUI

struct SetupView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                BrandHeading(bold: "Connect", italic: "Productive", size: 20)
                Text("Tempo tracks your time in Productive from the menu bar. Add your own API token to start.")
                    .font(Brand.font(12)).foregroundStyle(Brand.secondary)
            }
            .padding(16)
            ConnectionForm()
                .padding(.horizontal, 16)
            Spacer()
            AppFooter()
        }
    }
}

/// Token + organisation ID + "Test connection". Used by setup and settings.
struct ConnectionForm: View {
    @EnvironmentObject var store: TimeStore
    @State private var token = ""
    @State private var organizationID = ""
    @State private var message: String?
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("API token").font(Brand.font(11, .semibold)).foregroundStyle(Brand.secondary)
            SecureField("Paste your personal access token", text: $token).brandField()
            Text("Productive › Settings › API integrations › Generate new token (read/write).")
                .font(Brand.font(10)).foregroundStyle(Brand.secondary)

            Text("Organisation ID").font(Brand.font(11, .semibold)).foregroundStyle(Brand.secondary)
                .padding(.top, 4)
            TextField("For example 12345", text: $organizationID).brandField()
            Text("The number at the start of the path in your Productive web address, for example app.productive.io/12345-…")
                .font(Brand.font(10)).foregroundStyle(Brand.secondary)

            HStack {
                Button(testing ? "Testing…" : "Test connection") { test() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(testing || token.isEmpty || organizationID.isEmpty)
                    .keyboardShortcut(.defaultAction)
                if let message {
                    Text(message).font(Brand.font(11)).foregroundStyle(Brand.secondary).lineLimit(3)
                }
            }
            .padding(.top, 6)
        }
        .onAppear {
            token = store.storedToken
            organizationID = store.organizationID
            if let person = store.person { message = "Connected as \(person.name)" }
        }
    }

    private func test() {
        testing = true
        message = nil
        Task {
            if let person = await store.connect(token: token, organizationID: organizationID) {
                message = "Connected as \(person.name)"
            } else {
                message = store.lastError ?? "Could not connect."
            }
            testing = false
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: TimeStore
    @State private var target = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(bold: "Your", italic: "settings")
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    group("Connection") {
                        ConnectionForm()
                    }

                    group("Tracking") {
                        HStack {
                            Text("Weekly target").font(Brand.font(13))
                            Spacer()
                            TextField("37:30", text: $target)
                                .brandField()
                                .frame(width: 80)
                                .onSubmit(saveTarget)
                        }
                        HStack {
                            Text("Week starts on").font(Brand.font(13))
                            Spacer()
                            Picker("", selection: Binding(get: { store.firstWeekday }, set: { store.setFirstWeekday($0) })) {
                                Text("Monday").tag(2)
                                Text("Sunday").tag(1)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 150)
                        }
                        Toggle(isOn: $launchAtLogin) { Text("Start at login").font(Brand.font(13)) }
                            .toggleStyle(.switch)
                            .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                        if let loginError {
                            Text(loginError).font(Brand.font(10)).foregroundStyle(Brand.secondary)
                        }
                    }

                    group("Favourites") {
                        if store.favourites.isEmpty {
                            Text("Star a service in the picker to add it here.")
                                .font(Brand.italic(12)).foregroundStyle(Brand.secondary)
                        }
                        ForEach(store.favourites) { fav in
                            HStack(spacing: 4) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(fav.serviceName).font(Brand.font(12, .semibold)).lineLimit(1)
                                    Text(fav.service.context).font(Brand.font(10)).foregroundStyle(Brand.secondary).lineLimit(1)
                                }
                                Spacer()
                                IconButton(systemName: "arrow.up", help: "Move up") { store.moveFavourite(fav, by: -1) }
                                IconButton(systemName: "arrow.down", help: "Move down") { store.moveFavourite(fav, by: 1) }
                                IconButton(systemName: "xmark", help: "Remove") { store.removeFavourite(fav) }
                            }
                        }
                    }

                    Button("Sign out") { store.signOut() }
                        .buttonStyle(SecondaryButtonStyle())
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            AppFooter()
        }
        .onAppear { target = TimeFormat.hm(store.weeklyTargetMinutes) }
        .onDisappear(perform: saveTarget)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(bold: title, italic: "")
            VStack(alignment: .leading, spacing: 10, content: content).card()
        }
    }

    private func saveTarget() {
        if let minutes = TimeFormat.parseMinutes(target), minutes > 0 { store.setWeeklyTarget(minutes: minutes) }
        target = TimeFormat.hm(store.weeklyTargetMinutes)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "macOS did not allow this: \(error.localizedDescription). Move Tempo to Applications and try again."
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
