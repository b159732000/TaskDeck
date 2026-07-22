// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TaskDeck",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Fork adds: `transparentBackground` (default-bg cells left unpainted
        // so the glass shows through text rows) and inline IME marked-text
        // rendering (composing CJK painted into the grid, not a floating
        // bubble) — both candidates for upstream PR.
        .package(url: "https://github.com/b159732000/SwiftTerm.git",
                 revision: "d932d763921389e18d26effeb7433df280875c98"),
    ],
    targets: [
        .target(name: "TaskDeckCore"),
        .executableTarget(name: "taskdeckd", dependencies: ["TaskDeckCore"]),
        .executableTarget(name: "taskdeckctl", dependencies: ["TaskDeckCore"]),
        .executableTarget(
            name: "TaskDeck",
            dependencies: [
                "TaskDeckCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        // CLT toolchains ship neither XCTest nor swift-testing — self-checks
        // are a plain executable: `swift run taskdeck-selftest` (exit ≠ 0 on
        // failure).
        .executableTarget(name: "taskdeck-selftest", dependencies: ["TaskDeckCore"]),
        // Integration tests: spawns an ISOLATED taskdeckd on a temp socket
        // (never the production one) and exercises the wire protocol + pane
        // lifecycle. `swift run taskdeck-itest`, or Scripts/test.sh for all.
        .executableTarget(name: "taskdeck-itest", dependencies: ["TaskDeckCore"]),
    ]
)
