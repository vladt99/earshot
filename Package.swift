// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Earshot",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Speech: Parakeet TDT v3 ASR, pyannote diarization, LocalVQE echo cancellation (Apache-2.0)
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
        // Whisper large-v3-turbo for non-English languages (MIT)
        .package(url: "https://github.com/argmaxinc/WhisperKit", .upToNextMinor(from: "1.1.1")),
        // Auto-update: appcast + EdDSA-signed zips (MIT)
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Earshot",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"), .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Earshot",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // MCP server for Claude: a thin stdio client of the local API, shipped inside the app bundle.
        .executableTarget(name: "earshot-mcp", path: "Sources/EarshotMCP", swiftSettings: [.swiftLanguageMode(.v5)]),
        // Pure logic only: no models, audio devices or network.
        .testTarget(name: "EarshotTests", dependencies: ["Earshot"], path: "Tests/EarshotTests", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
