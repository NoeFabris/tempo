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

/// The refresh button: a click turns the arrow once around its centre; it keeps turning while
/// `isRefreshing` is true and always stops upright.
struct RefreshButton: View {
    var help: String = ""
    let isRefreshing: Bool
    let action: () -> Void
    @State private var turns = 0.0
    @State private var spinning = false
    /// Mirrors `isRefreshing`: the animation's completion reads it after the view has changed.
    @State private var busy = false

    var body: some View {
        Button {
            action()
            spin()
        } label: {
            RefreshGlyph()
                .stroke(Brand.secondary, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                .frame(width: 13, height: 13)
                .rotationEffect(.degrees(turns * 360))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onAppear { busy = isRefreshing }
        .onChange(of: isRefreshing) { _, on in
            busy = on
            if on { spin() }
        }
    }

    private func spin() {
        guard !spinning else { return }
        spinning = true
        turn()
    }

    private func turn() {
        withAnimation(.linear(duration: 0.8)) { turns += 1 } completion: {
            if busy { turn() } else { spinning = false }
        }
    }
}

/// A refresh arrow drawn on the centre of its frame, like `arrow.clockwise`: an arc from three o'clock,
/// clockwise round to the top, with an open head. The SF Symbol's circle is off its centre, so it wobbles
/// when it turns.
struct RefreshGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY), r = min(rect.width, rect.height) / 2 * 0.78
        let end = 0.8 * 2 * Double.pi // y points down, so increasing angles go clockwise
        let p = CGPoint(x: c.x + r * cos(end), y: c.y + r * sin(end))
        let tangent = CGPoint(x: -sin(end), y: cos(end)), normal = CGPoint(x: cos(end), y: sin(end))
        let head = r * 0.5
        let tip = CGPoint(x: p.x + tangent.x * head * 0.15, y: p.y + tangent.y * head * 0.15)
        var path = Path()
        path.addArc(center: c, radius: r, startAngle: .zero, endAngle: .radians(end), clockwise: false)
        path.move(to: CGPoint(x: tip.x - (tangent.x - normal.x) * head, y: tip.y - (tangent.y - normal.y) * head))
        path.addLine(to: tip)
        path.addLine(to: CGPoint(x: tip.x - (tangent.x + normal.x) * head, y: tip.y - (tangent.y + normal.y) * head))
        return path
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
