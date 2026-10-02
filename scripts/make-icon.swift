// Draws the Tempo app icon and writes Resources/AppIcon.icns and docs/images/icon.png.
//   swift scripts/make-icon.swift            (run in the repository root)
//   swift scripts/make-icon.swift --variants <dir>   (writes design variants as PNG files only)
// The icon follows the macOS grid: a 824 pt rounded square with continuous corners on a 1024 pt canvas.
// Black leads; Mellow Yellow only on black; violet is a small accent (the running dot of the popup).
import AppKit
import SwiftUI

let yellow = Color(red: 0xF2 / 255, green: 0xFA / 255, blue: 0x7A / 255)
let violet = Color(red: 0x75 / 255, green: 0x46 / 255, blue: 0xFF / 255)

/// A play triangle with rounded corners, pointing right, filling its frame.
struct PlayShape: Shape {
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let a = CGPoint(x: rect.minX, y: rect.minY)
        let b = CGPoint(x: rect.maxX, y: rect.midY)
        let c = CGPoint(x: rect.minX, y: rect.maxY)
        var path = Path()
        path.move(to: CGPoint(x: (a.x + c.x) / 2, y: (a.y + c.y) / 2))
        path.addArc(tangent1End: a, tangent2End: b, radius: cornerRadius)
        path.addArc(tangent1End: b, tangent2End: c, radius: cornerRadius)
        path.addArc(tangent1End: c, tangent2End: a, radius: cornerRadius)
        path.closeSubpath()
        return path
    }
}

struct Icon: View {
    enum Variant: String, CaseIterable { case ring, ringDot, play }
    let variant: Variant

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.14), .black], startPoint: .top, endPoint: .bottom))
                .frame(width: 824, height: 824)
            switch variant {
            case .ring, .ringDot:
                // The time ring: a dim track and three quarters of a turn in yellow, from twelve o'clock.
                Circle().stroke(Color(white: 0.2), lineWidth: 58).frame(width: 520, height: 520)
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(yellow, style: StrokeStyle(lineWidth: 58, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 520, height: 520)
                if variant == .ringDot {
                    Circle().fill(violet).frame(width: 92, height: 92).offset(x: -260)
                }
                PlayShape(cornerRadius: 26).fill(Color.white).frame(width: 196, height: 220).offset(x: 18)
            case .play:
                PlayShape(cornerRadius: 56).fill(yellow).frame(width: 400, height: 450).offset(x: 34)
            }
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor
func png(_ variant: Icon.Variant, pixels: Int) -> Data {
    let renderer = ImageRenderer(content: Icon(variant: variant))
    renderer.scale = CGFloat(pixels) / 1024
    let rep = NSBitmapImageRep(cgImage: renderer.cgImage!)
    return rep.representation(using: .png, properties: [:])!
}

@MainActor
func main() throws {
    let args = CommandLine.arguments
    let fm = FileManager.default
    if let i = args.firstIndex(of: "--variants"), i + 1 < args.count {
        let dir = URL(fileURLWithPath: args[i + 1])
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for v in Icon.Variant.allCases { try png(v, pixels: 1024).write(to: dir.appendingPathComponent("icon-\(v.rawValue).png")) }
        return
    }
    let variant = Icon.Variant.ringDot
    let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: iconset) }
    for points in [16, 32, 128, 256, 512] {
        try png(variant, pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
        try png(variant, pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
    }
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else { throw NSError(domain: "iconutil", code: Int(iconutil.terminationStatus)) }
    try fm.createDirectory(atPath: "docs/images", withIntermediateDirectories: true)
    try png(variant, pixels: 256).write(to: URL(fileURLWithPath: "docs/images/icon.png"))
    print("Wrote Resources/AppIcon.icns and docs/images/icon.png")
}

try MainActor.assumeIsolated { try main() }
