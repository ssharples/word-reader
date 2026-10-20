// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WordReader",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ReaderKit", targets: ["ReaderKit", "ReaderCore"]),
        .executable(name: "WordReader", targets: ["WordReader"]),
        .executable(name: "epub-check", targets: ["epub-check"]),
    ],
    targets: [
        // EPUB opening, text extraction and word timing. No UI.
        .target(name: "ReaderCore"),
        // What the Mac and iPhone apps share: playback, progress, sync and the word display.
        .target(name: "ReaderKit", dependencies: ["ReaderCore"]),
        // The Mac app. The iPhone app is in iOS/.
        .executableTarget(name: "WordReader", dependencies: ["ReaderCore", "ReaderKit"]),
        // Command-line check that opens books and reports what it found.
        .executableTarget(name: "epub-check", dependencies: ["ReaderCore"]),
        .testTarget(name: "ReaderCoreTests", dependencies: ["ReaderCore"]),
        .testTarget(name: "ReaderKitTests", dependencies: ["ReaderCore", "ReaderKit"]),
    ]
)
