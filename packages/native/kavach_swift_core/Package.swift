// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KavachSwiftCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "KavachSwiftCore", targets: ["KavachSwiftCore"])
    ],
    targets: [
        .target(name: "KavachSwiftCore"),
        .testTarget(name: "KavachSwiftCoreTests", dependencies: ["KavachSwiftCore"]),
    ]
)
