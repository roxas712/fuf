// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FlockCore",
    // macOS is listed so `swift test` runs on the command line with no
    // simulator; iOS is what the app target actually links against.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FlockCore", targets: ["FlockCore"]),
    ],
    targets: [
        .target(name: "FlockCore"),
        .testTarget(name: "FlockCoreTests", dependencies: ["FlockCore"]),
    ]
)
