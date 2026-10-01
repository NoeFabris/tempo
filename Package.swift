// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Tempo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Tempo", targets: ["Tempo"]),
    ],
    dependencies: [
        // Updates. Binary target; the signing tools come with it (.build/artifacts/sparkle/Sparkle/bin).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(name: "ProductiveCore"),
        .executableTarget(
            name: "Tempo",
            dependencies: ["ProductiveCore", .product(name: "Sparkle", package: "Sparkle")]
        ),
        .testTarget(
            name: "ProductiveCoreTests",
            dependencies: ["ProductiveCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
