// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Earshot",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Speech: Parakeet TDT v3 ASR, pyannote diarization, LocalVQE echo cancellation (Apache-2.0)
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
    ],
    targets: [
        .executableTarget(
            name: "Earshot",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Earshot",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // MCP server for Claude: a thin stdio client of the local API, shipped inside the app bundle.
        .executableTarget(name: "earshot-mcp", path: "Sources/EarshotMCP", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
