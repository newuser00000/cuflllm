// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "cuflllm",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "CuflCore", targets: ["CuflCore"]),
        .executable(name: "cuflllm", targets: ["cuflllm"])
    ],
    targets: [
        .target(
            name: "CuflCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision")
            ]
        ),
        .executableTarget(
            name: "cuflllm",
            dependencies: ["CuflCore"]
        ),
        .testTarget(
            name: "CuflCoreTests",
            dependencies: ["CuflCore"]
        )
    ]
)
