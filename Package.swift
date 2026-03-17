// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentHub",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "AgentHub",
            path: "Sources",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
