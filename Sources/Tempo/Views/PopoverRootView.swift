import ProductiveCore
import SwiftUI

struct PopoverRootView: View {
    @EnvironmentObject var store: TimeStore
    @EnvironmentObject var nav: Navigator

    var body: some View {
        Group {
            if store.phase == .setup {
                SetupView()
            } else {
                switch nav.screen {
                case .main: MainView()
                case .picker(let mode): ServicePickerView(mode: mode)
                case .add(let service): EntryFormView(entry: nil, service: service)
                case .edit(let entry): EntryFormView(entry: entry, service: entry.service)
                case .settings: SettingsView()
                }
            }
        }
        .frame(width: 340, height: 520)
        .background(Brand.background)
        .foregroundStyle(Brand.text)
        .tint(Brand.violet)
    }
}

/// Top bar for sub-screens: back arrow + heading.
struct ScreenHeader: View {
    @EnvironmentObject var nav: Navigator
    let bold: String
    let italic: String
    var back: Navigator.Screen = .main

    var body: some View {
        HStack(spacing: 6) {
            IconButton(systemName: "chevron.left", help: "Back") { nav.screen = back }
            BrandHeading(bold: bold, italic: italic, size: 16)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

struct AppFooter: View {
    var body: some View {
        HStack(spacing: 4) {
            Text("Acme Agency Ltd \(String(Calendar.current.component(.year, from: Date()))) ·")
            Link(destination: URL(string: "https://example.com")!) {
                Text("example.com").font(Brand.font(10, .bold)).foregroundStyle(Brand.text)
            }
        }
        .font(Brand.font(10))
        .foregroundStyle(Brand.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}
