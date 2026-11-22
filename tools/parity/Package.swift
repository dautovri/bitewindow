// swift-tools-version: 5.9
// Writes the golden file the Kotlin port is checked against (core/src/test/resources/golden.json)
// by running the real Swift engine (the BiteCore package at the repository root) on fixed inputs.
//   cd tools/parity && swift run parity ../../web/test/golden.json   (also used for android/core/src/test/resources/golden.json)
import PackageDescription

let package = Package(
    name: "parity",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "BiteCore", path: "../..")],
    targets: [
        .executableTarget(name: "parity", dependencies: [.product(name: "BiteCore", package: "BiteCore")]),
    ]
)
