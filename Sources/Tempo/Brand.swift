import AppKit
import SwiftUI

/// Colour and type tokens. Black, white and off-white lead; violet and yellow are small accents.
enum Brand {
    static let violet = Color(hex: 0x7546FF)
    static let yellow = Color(hex: 0xF2FA7A) // Only on black.

    static let background = Color(light: 0xF1EFE9, dark: 0x000000)
    static let card = Color(light: 0xFFFFFF, dark: 0x141414)
    static let text = Color(light: 0x000000, dark: 0xFFFFFF)
    static let secondary = Color(light: 0x5A5A5A, dark: 0x9A9A9A)
    static let separator = Color(light: 0xDDDAD2, dark: 0x262626)
    /// Text on a violet fill.
    static let onViolet = Color.white

    static let nsViolet = NSColor(srgbRed: 0x75 / 255, green: 0x46 / 255, blue: 0xFF / 255, alpha: 1)

    // MARK: Type (Inter Tight, bundled; falls back to the system font in debug runs)

    static let family = "Inter Tight"
    static let hasInterTight = NSFontManager.shared.availableMembers(ofFontFamily: family) != nil

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        (hasInterTight ? Font.custom(family, size: size) : Font.system(size: size)).weight(weight)
    }

    static func italic(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        font(size, weight).italic()
    }

    /// Tabular figures so times do not move when they change.
    static func digits(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        font(size, weight).monospacedDigit()
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }

    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// The heading style: a bold anchor followed by an italic qualifier.
struct BrandHeading: View {
    let bold: String
    let italic: String
    var size: CGFloat = 15

    var body: some View {
        (Text(bold).font(Brand.font(size, .bold)) + Text(" ") + Text(italic).font(Brand.italic(size, .regular)))
            .foregroundStyle(Brand.text)
    }
}

struct IconButton: View {
    let systemName: String
    var help: String = ""
    var tint: Color = Brand.secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledPrimary(configuration: configuration)
    }

    private struct StyledPrimary: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
            .font(Brand.font(13, .semibold))
            .foregroundStyle(Brand.onViolet)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Brand.violet.opacity(configuration.isPressed ? 0.8 : 1)))
            .opacity(isEnabled ? 1 : 0.4)
        }
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledSecondary(configuration: configuration)
    }

    private struct StyledSecondary: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(Brand.font(13, .medium))
                .foregroundStyle(Brand.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).stroke(Brand.separator))
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
        }
    }
}

struct BrandField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(Brand.font(13))
            .foregroundStyle(Brand.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Brand.card))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.separator))
    }
}

extension View {
    func brandField() -> some View { modifier(BrandField()) }

    func card() -> some View {
        padding(12).background(RoundedRectangle(cornerRadius: 8).fill(Brand.card))
    }
}
