import SwiftUI

/// 集成测试宿主：只提供一个有 bundle 身份、带 NSPhotoLibraryUsageDescription 的进程。
@main
struct PPassMediaHostApp: App {
    var body: some Scene {
        WindowGroup { Text("PPassMedia integration host") }
    }
}
