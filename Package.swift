// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WordReader",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "WordReader", targets: ["WordReader"]),
        .executable(name: "epub-check", targets: ["epub-check"]),
    ],
    targets: [
        // EPUB opening, text extraction and word timing. No UI.
        .target(name: "ReaderCore"),
        // The Mac app.
        .executableTarget(name: "WordReader", dependencies: ["ReaderCore"]),
        // Command-line check that opens books and reports what it found.
        .executableTarget(name: "epub-check", dependencies: ["ReaderCore"]),
        .testTarget(name: "ReaderCoreTests", dependencies: ["ReaderCore"]),
    ]
)
