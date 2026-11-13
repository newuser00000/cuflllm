// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "cufl",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "CuflCore", targets: ["CuflCore"]),
        .executable(name: "cufl", targets: ["cufl"])
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
            name: "cufl",
            dependencies: ["CuflCore"]
        ),
        .testTarget(
            name: "CuflCoreTests",
            dependencies: ["CuflCore"]
        )
    ]
)
