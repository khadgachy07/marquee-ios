// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Marquee",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        // xtool bundles this library into the iOS app.
        .library(name: "Marquee", targets: ["Marquee"]),
    ],
    targets: [
        // Jellyfin API, models and the device profile. Plain Foundation, so it also builds and
        // tests on Linux/macOS: `swift test`.
        .target(name: "MarqueeCore"),
        // The iPhone app (SwiftUI + AVKit). Its files are wrapped in `#if os(iOS)`.
        .target(
            name: "Marquee",
            dependencies: ["MarqueeCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "MarqueeCoreTests", dependencies: ["MarqueeCore"]),
    ]
)
