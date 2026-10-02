// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Kleio",
    platforms: [
        .macOS(.v15)
    ],
    products: [.executable(name: "Kleio", targets: ["Scribe"])],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        // Pinned to the minor: FluidAudio is pre-1.0 and ships breaking changes in
        // minor releases. 0.17 adds Parakeet v2/v3 file transcription.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", .upToNextMinor(from: "0.17.5"))
    ],
    targets: [
        .executableTarget(
            name: "Scribe",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/Scribe",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "ScribeTests",
            dependencies: ["Scribe"],
            path: "Tests/ScribeTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
