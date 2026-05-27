// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BoleraCore",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "BoleraCore", targets: ["BoleraCore"])
    ],
    targets: [
        .target(
            name: "BoleraCore",
            path: "Sources/BoleraCore"
        )
    ]
)
