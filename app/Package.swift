// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LayoutSwitcher",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure, deterministic, testable core. No AppKit / no permissions.
        .target(
            name: "SwitcherCore",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Menu-bar agent: CGEventTap, TIS, AppKit/SwiftUI UI, lifecycle.
        .executableTarget(
            name: "LayoutSwitcher",
            dependencies: ["SwitcherCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SwitcherCoreTests",
            dependencies: ["SwitcherCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
