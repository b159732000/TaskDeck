// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TaskDeck",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
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
