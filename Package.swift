// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UltaMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "UltaMac", targets: ["UltaMac"]),
        .library(name: "UltaMacCore", targets: ["UltaMacCore"]),
    ],
    targets: [
        .target(
            name: "UltaMacCore",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "UltaMac",
            dependencies: ["UltaMacCore"]
        ),
        .testTarget(
            name: "UltaMacCoreTests",
            dependencies: ["UltaMacCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
