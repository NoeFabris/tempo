// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Tempo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Tempo", targets: ["Tempo"]),
    ],
    targets: [
        .target(name: "ProductiveCore"),
        .executableTarget(name: "Tempo", dependencies: ["ProductiveCore"]),
        .testTarget(
            name: "ProductiveCoreTests",
            dependencies: ["ProductiveCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
