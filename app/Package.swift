// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "decarta",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "decarta",
            path: "Sources/decarta",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)