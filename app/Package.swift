// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Decarta",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Decarta",
            path: "Sources/Decarta",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)