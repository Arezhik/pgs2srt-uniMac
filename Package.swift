// swift-tools-version:5.9
import PackageDescription

#if os(macOS)
// AppKit forwarding tests. Linux CI never builds this target.
let reviewDelegateProxyTargets: [Target] = [
    .target(
        name: "ReviewDelegateProxy",
        path: "App/ReviewDelegateProxy",
        publicHeadersPath: "include",
        linkerSettings: [
            .linkedFramework("AppKit")
        ]
    ),
    .testTarget(
        name: "ReviewDelegateProxyTests",
        dependencies: ["ReviewDelegateProxy"],
        path: "App/ReviewDelegateProxyTests"
    )
]
#else
let reviewDelegateProxyTargets: [Target] = []
#endif

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
        .systemLibrary(
            name: "CZLib",
            path: "Sources/CZLib"
        ),
        .target(
            name: "PGSCore",
            dependencies: ["CZLib"]
        ),
        .target(name: "VisionOCR", dependencies: ["PGSCore"]),
        .executableTarget(name: "pgsdump", dependencies: ["PGSCore"]),
        .executableTarget(name: "pgs2srt", dependencies: ["PGSCore", "VisionOCR"]),
        .testTarget(
            name: "PGSCoreTests",
            dependencies: ["PGSCore", "VisionOCR"],
            exclude: ["Fixtures/mkv"]
        )
    ] + reviewDelegateProxyTargets
)
