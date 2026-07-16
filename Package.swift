// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ProcrastinationBlocker",
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "ProcrastinationBlockerCore",
            targets: ["ProcrastinationBlockerCore"]
        ),
        .executable(
            name: "ProcrastinationBlocker",
            targets: ["ProcrastinationBlocker"]
        ),
        .executable(
            name: "ProcrastinationBlockerHelper",
            targets: ["ProcrastinationBlockerHelper"]
        ),
    ],
    targets: [
        .target(name: "ProcrastinationBlockerCore"),
        .executableTarget(
            name: "ProcrastinationBlocker",
            dependencies: ["ProcrastinationBlockerCore"]
        ),
        .executableTarget(
            name: "ProcrastinationBlockerHelper",
            dependencies: ["ProcrastinationBlockerCore"]
        ),
        .testTarget(
            name: "ProcrastinationBlockerCoreTests",
            dependencies: ["ProcrastinationBlockerCore"]
        ),
    ]
)
