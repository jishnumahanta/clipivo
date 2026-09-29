// swift-tools-version: 6.0
import PackageDescription

// Clipivo is split into three layers:
//   ClipivoCore    – platform-neutral domain logic (models, SQLite persistence, search,
//                    classification, sensitive-content detection, blob storage, archives).
//                    Depends only on Foundation, SQLite and CryptoKit so it can be ported.
//   ClipivoMacKit  – macOS platform services (pasteboard, paste, hotkeys, OCR, thumbnails,
//                    lock) and the AppKit/SwiftUI user interface.
//   Clipivo        – the tiny executable entry point.
let package = Package(
    name: "Clipivo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Clipivo", targets: ["Clipivo"]),
        .library(name: "ClipivoCore", targets: ["ClipivoCore"]),
    ],
    targets: [
        .target(
            name: "ClipivoCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "ClipivoMacKit",
            dependencies: ["ClipivoCore"]
        ),
        .executableTarget(
            name: "Clipivo",
            dependencies: ["ClipivoMacKit"]
        ),
        .testTarget(
            name: "ClipivoCoreTests",
            dependencies: ["ClipivoCore"]
        ),
        .testTarget(
            name: "ClipivoMacKitTests",
            dependencies: ["ClipivoMacKit", "ClipivoCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
