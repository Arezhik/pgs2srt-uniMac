// swift-tools-version:5.9
import PackageDescription

let package = Package(
    // Not "PGS2SRT". That is the Xcode project's name, and the IDE drops the
    // products when the package and the project share a name and a folder.
    name: "PGS2SRTKit",
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
