// swift-tools-version:5.9
//
// PPassCore：iOS 端的业务核心（纯 Swift，不依赖 UIKit / PhotoKit / FFI）。
// 平台依赖（媒体源、BLAKE3、控制面传输、时钟、存储根目录）一律走 protocol 注入；
// macOS 只为 host 上跑 `swift test`，产品只上 iOS。
import PackageDescription

let package = Package(
    name: "PPassCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "PPassCore", targets: ["PPassCore"]),
    ],
    targets: [
        .target(name: "PPassCore"),
        .testTarget(name: "PPassCoreTests", dependencies: ["PPassCore"]),
    ]
)
