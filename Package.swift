// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BiteCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "BiteCore", targets: ["BiteCore"]),
    ],
    targets: [
        .target(name: "BiteCore"),
        .testTarget(name: "BiteCoreTests", dependencies: ["BiteCore"]),
    ]
)
