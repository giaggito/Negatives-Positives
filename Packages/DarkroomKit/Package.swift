// swift-tools-version: 6.0
import Foundation
import PackageDescription

// DarkroomKit: everything the Negatives converter and the Positives editor share —
// raw decoding (LibRaw), colour science, the float GPU layer, export, and the UI design system.
//
// LibRaw parallelises X-Trans demosaicing and Fuji decompression with OpenMP. Apple's clang supports it
// with Homebrew's libomp (linked statically, so the built apps have no runtime dependency on Homebrew).
// Without libomp everything still builds, single-threaded (~2x slower decoding).
let libomp = "/opt/homebrew/opt/libomp"
let hasOpenMP = FileManager.default.fileExists(atPath: libomp + "/lib/libomp.a")
let openMPFlags: [String] = hasOpenMP ? ["-Xclang", "-fopenmp", "-I\(libomp)/include"] : []
let openMPLink: [LinkerSetting] = hasOpenMP ? [.unsafeFlags(["\(libomp)/lib/libomp.a", "-Xlinker", "-w"])] : []

// JPEG export uses libjpeg-turbo (Homebrew `jpeg-turbo`, linked statically) for full control: any quality
// with 4:4:4 chroma, optimised tables. Without it, export falls back to ImageIO (4:4:4 only at quality 100).
let turbo = "/opt/homebrew/opt/jpeg-turbo"
let hasTurbo = FileManager.default.fileExists(atPath: turbo + "/lib/libturbojpeg.a")

// LibRaw also reads Deflate-compressed DNGs (Adobe DNG Converter, merged HDRs) with the system zlib, and
// lossy DNGs with libjpeg (from the same jpeg-turbo, linked statically).
let libRawCodecs: [CXXSetting] = [.define("USE_ZLIB")] + (hasTurbo ? [.define("USE_JPEG"), .unsafeFlags(["-I\(turbo)/include"])] : [])
let libRawCodecLink: [LinkerSetting] = [.linkedLibrary("z")] + (hasTurbo ? [.unsafeFlags(["\(turbo)/lib/libjpeg.a"])] : [])

let package = Package(
    name: "DarkroomKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DarkroomCore", targets: ["DarkroomCore"]),
        .library(name: "DarkroomUI", targets: ["DarkroomUI"]),
    ],
    targets: [
        // LibRaw 0.22.2, vendored unmodified (dual LGPL-2.1 / CDDL-1.0, see Vendor/LibRaw/COPYRIGHT).
        .target(
            name: "CLibRaw",
            path: "Vendor/LibRaw",
            exclude: [
                "COPYRIGHT", "Changelog.txt", "LICENSE.CDDL", "LICENSE.LGPL", "README.md",
                "src/postprocessing/postprocessing_ph.cpp",
                "src/preprocessing/preprocessing_ph.cpp",
                "src/write/write_ph.cpp",
            ],
            sources: ["src"],
            publicHeadersPath: "spm-include",
            cxxSettings: [
                .headerSearchPath("."),
                // Always optimise: an unoptimised X-Trans demosaic is ~10x slower, even in Debug.
                .unsafeFlags(["-O3", "-w"] + openMPFlags),
            ] + libRawCodecs,
            linkerSettings: openMPLink + libRawCodecLink
        ),
        .target(
            name: "DarkroomCore",
            dependencies: ["CLibRaw"] + (hasTurbo ? ["CTurboJPEG"] : []),
            resources: [.copy("Resources/GPL-3.0.txt"), .copy("Resources/LIBRAW_LICENSE.txt"),
                        .copy("Resources/LIBJPEG_TURBO_LICENSE.txt"), .copy("Resources/LIBOMP_LICENSE.txt")],
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        ),
        .target(
            name: "CTurboJPEG",
            cSettings: [.unsafeFlags(["-I\(turbo)/include", "-O2"])],
            linkerSettings: [.unsafeFlags(["\(turbo)/lib/libturbojpeg.a"])]
        ),
        .target(
            name: "DarkroomUI",
            dependencies: ["DarkroomCore"]
        ),
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .gnucxx14
)
