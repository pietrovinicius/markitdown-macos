// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MarkItDownMac",
    defaultLocalization: "pt-BR",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "MarkItDownMacCore",
            targets: ["MarkItDownMacCore"]
        ),
        .executable(
            name: "MarkItDownMac",
            targets: ["MarkItDownMac"]
        )
    ],
    targets: [
        .target(
            name: "MarkItDownMacCore",
            path: "Sources/MarkItDownMacCore"
        ),
        .executableTarget(
            name: "MarkItDownMac",
            dependencies: ["MarkItDownMacCore"],
            path: "Sources/MarkItDownMac"
        ),
        .testTarget(
            name: "MarkItDownMacTests",
            dependencies: ["MarkItDownMacCore"],
            path: "Tests/MarkItDownMacTests"
        )
    ]
)
