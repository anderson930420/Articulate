// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Articulate",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Articulate",
            path: "Sources/Articulate"
        )
    ],
    swiftLanguageModes: [.v5]
)
