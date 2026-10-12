// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PPassMedia",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "PPassMedia", targets: ["PPassMedia"]),
    ],
    targets: [
        .target(name: "PPassMedia"),
        .testTarget(name: "PPassMediaTests", dependencies: ["PPassMedia"]),
    ]
)
