// swift-tools-version:6.0
import Foundation
import PackageDescription

// Developer tools (benchmarks, experiments) live in Sources/ArticulateCore/Lab on the development Mac only;
// that folder is not in the repository. When it is there, they are built in and their commands enabled.
let lab = FileManager.default.fileExists(
    atPath: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Sources/ArticulateCore/Lab").path)

let package = Package(
    name: "Articulate",
    platforms: [.macOS("26.0")],
    targets: [
        .target(
            name: "ArticulateCore",
            path: "Sources/ArticulateCore",
            swiftSettings: lab ? [.define("ARTICULATE_LAB")] : []
        ),
        .executableTarget(
            name: "Articulate",
            dependencies: ["ArticulateCore"],
            path: "Sources/Articulate"
        ),
        .testTarget(
            name: "ArticulateTests",
            dependencies: ["ArticulateCore"],
            path: "Tests/ArticulateTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
