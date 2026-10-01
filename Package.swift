// swift-tools-version: 6.2
import PackageDescription

// Layout and ownership: SPEC.md §7. Build with a private scratch path per component, e.g.
// `swift build --scratch-path .build-c1` (SPEC §0).
let package = Package(
    name: "Tiler",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TilerCore", targets: ["TilerCore"]),
    ],
    targets: [
        // C1: pure logic (no AppKit windows, no AX). Swift 6 mode, deliberately NOT
        // default-MainActor so it is usable from any isolation domain and from tests.
        .target(
            name: "TilerCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // C2: the AX window engine (SPEC §3). A library so both the app and tiler-harness use it.
        .target(
            name: "TilerAX",
            dependencies: ["TilerCore"],
            swiftSettings: [.swiftLanguageMode(.v6), .defaultIsolation(MainActor.self)]
        ),
        // The menu-bar app (C2 Windows/ re-exports TilerAX, C3 Hover/ + Palette/, C4 App/).
        .executableTarget(
            name: "Tiler",
            dependencies: ["TilerCore", "TilerAX"],
            swiftSettings: [.swiftLanguageMode(.v6), .defaultIsolation(MainActor.self)]
        ),
        // C2: test helper app that opens standard windows for live tests.
        .executableTarget(
            name: "TilerTestWindows",
            swiftSettings: [.swiftLanguageMode(.v6), .defaultIsolation(MainActor.self)]
        ),
        // Shared helpers for the live-UI test executables below (report table, waiting, HID
        // events, AX/CG lookups, palette-over-AX reading, the live-UI lock and process cleanup) —
        // factored out so a fix to e.g. lock handling or cursor restore is made once, not per
        // executable. See its own file header for what is and is not shared and why.
        .target(
            name: "TilerTestSupport",
            dependencies: ["TilerCore", "TilerAX"],
            swiftSettings: [.swiftLanguageMode(.v6), .defaultIsolation(MainActor.self)]
        ),
        // C2: CLI that drives every preset against TilerTestWindows windows.
        .executableTarget(
            name: "tiler-harness",
            dependencies: ["TilerCore", "TilerAX", "TilerTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6), .defaultIsolation(MainActor.self)]
        ),
        // C3: live test of the palette triggers (menu-bar click, hotkey, keyboard) on TilerTestWindows.
        .executableTarget(
            name: "tiler-palettetest",
            dependencies: ["TilerCore", "TilerAX", "TilerTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6), .defaultIsolation(MainActor.self)]
        ),
        // C5: live test of the hover trigger + native-menu suppression on TilerTestWindows.
        .executableTarget(
            name: "tiler-hovertest",
            dependencies: ["TilerCore", "TilerAX", "TilerTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6), .defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "TilerCoreTests",
            dependencies: ["TilerCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
