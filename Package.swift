// swift-tools-version: 6.0
import PackageDescription

// The two apps' engines. Shared code (raw decoding, colour, GPU, export, UI) lives in Packages/DarkroomKit.
let package = Package(
    name: "Darkroom",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NegativesCore", targets: ["NegativesCore"]),
        .library(name: "PositivesCore", targets: ["PositivesCore"]),
        .executable(name: "negatives-cli", targets: ["negatives-cli"]),
        .executable(name: "positives-cli", targets: ["positives-cli"]),
    ],
    dependencies: [
        .package(path: "Packages/DarkroomKit"),
    ],
    targets: [
        .target(
            name: "NegativesCore",
            dependencies: [.product(name: "DarkroomCore", package: "DarkroomKit")],
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        ),
        .executableTarget(name: "negatives-cli", dependencies: ["NegativesCore"]),
        .testTarget(name: "NegativesCoreTests", dependencies: ["NegativesCore"]),

        .target(
            name: "PositivesCore",
            dependencies: [.product(name: "DarkroomCore", package: "DarkroomKit")],
            resources: [.copy("Resources/SkySegmentation.mlmodelc"), .copy("Resources/SKY_MODEL_LICENSE.txt"), .copy("Resources/FilmLooks.lzfse"), .copy("Resources/FILM_LOOKS_LICENSE.txt"), .copy("Resources/FilmData.json"), .copy("Resources/FILM_DATA_LICENSE.txt"), .copy("Resources/FILM_DATA_CHANGELOG.txt")],
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        ),
        .executableTarget(name: "positives-cli", dependencies: ["PositivesCore"]),
        // Test bench for Negatives: synthetic scans of real film stocks (spectral data from PositivesCore) under
        // many cameras, lights, exposures and framings, converted and scored.
        .target(name: "NegativesBench", dependencies: ["NegativesCore", "PositivesCore"],
                swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]),
        .executableTarget(name: "negatives-bench", dependencies: ["NegativesBench", "NegativesCore", "PositivesCore"],
                          swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]),
        .testTarget(name: "NegativesSpectralTests", dependencies: ["NegativesBench", "NegativesCore", "PositivesCore"]),
        .testTarget(name: "PositivesCoreTests", dependencies: ["PositivesCore"]),
    ],
    swiftLanguageModes: [.v5]
)
