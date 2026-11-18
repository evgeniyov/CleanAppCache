// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CleanAppCache",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CleanAppCache", targets: ["CleanAppCache"]),
        .library(name: "CleanAppCacheLib", targets: ["CleanAppCacheLib"])
    ],
    targets: [
        .executableTarget(
            name: "CleanAppCache",
            dependencies: ["CleanAppCacheLib"],
            path: "Sources/CleanAppCache"
        ),
        .target(
            name: "CleanAppCacheLib",
            dependencies: [],
            path: "Sources/CleanAppCacheLib",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "CleanAppCacheTests",
            dependencies: ["CleanAppCacheLib"],
            path: "Tests/CleanAppCacheTests"
        )
    ]
)
