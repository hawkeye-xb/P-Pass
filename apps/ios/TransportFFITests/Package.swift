// swift-tools-version:5.9
// IOS-06（#313）：transport XCFramework 的最小 Swift 消费方 + 模拟器测试。
//
// Generated/ 不入库，由 tools/ios/test-transport-ffi.sh 调
// tools/build-ios-transport-xcframework.sh 生成（SwiftPM 要求本地 binaryTarget 在包目录内）。
// 跑法：tools/ios/test-transport-ffi.sh
import PackageDescription

let package = Package(
    name: "TransportFFITests",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "PPassTransport", targets: ["PPassTransport"]),
    ],
    dependencies: [
        // 只给测试用：PPassCore（#890）的 Codable FlowFetchRequest 编出的 JSON 要能被 crates/proto 解码。
        .package(path: "../Packages/PPassCore"),
    ],
    targets: [
        .binaryTarget(name: "TransportFFI", path: "Generated/TransportFFI.xcframework"),
        // UniFFI 生成的 Swift 绑定（import transportFFI），不手写一行。
        .target(
            name: "PPassTransport",
            dependencies: ["TransportFFI"],
            path: "Generated/swift",
            linkerSettings: [
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Security"),
                .linkedFramework("Network"),
            ]
        ),
        .testTarget(
            name: "TransportFFITests",
            dependencies: ["PPassTransport", .product(name: "PPassCore", package: "PPassCore")],
            path: "Tests/TransportFFITests"
        ),
    ]
)
