// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PGS2SRT",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "PGSCore", targets: ["PGSCore"]),
        .executable(name: "pgsdump", targets: ["pgsdump"])
    ],
    targets: [
        .target(name: "PGSCore"),
        .executableTarget(name: "pgsdump", dependencies: ["PGSCore"]),
        .testTarget(name: "PGSCoreTests", dependencies: ["PGSCore"])
    ]
)
