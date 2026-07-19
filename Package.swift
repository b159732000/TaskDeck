// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TaskDeck",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Fork adds `transparentBackground` (default-bg cells left unpainted
        // so the glass shows through text rows) — candidate for upstream PR.
        .package(url: "https://github.com/b159732000/SwiftTerm.git",
                 revision: "4c805c690721b8c8c4df2827c41d89fe84418df2"),
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
    ]
)
