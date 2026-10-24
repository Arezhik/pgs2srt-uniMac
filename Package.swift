// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PGS2SRT",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "PGSCore", targets: ["PGSCore"]),
        .library(name: "VisionOCR", targets: ["VisionOCR"]),
        .executable(name: "pgsdump", targets: ["pgsdump"]),
        .executable(name: "pgs2srt", targets: ["pgs2srt"])
    ],
    targets: [
        .target(name: "PGSCore"),
        .target(name: "VisionOCR", dependencies: ["PGSCore"]),
        .executableTarget(name: "pgsdump", dependencies: ["PGSCore"]),
        .executableTarget(name: "pgs2srt", dependencies: ["PGSCore", "VisionOCR"]),
        .testTarget(name: "PGSCoreTests", dependencies: ["PGSCore", "VisionOCR"])
    ]
)
