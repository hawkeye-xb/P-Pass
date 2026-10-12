import Foundation

/// 测试里定位仓库根目录：本文件在 `apps/ios/PPassTests/`，往上三级目录就是仓库根。
/// 模拟器进程能直接读宿主文件系统，所以漂移测试读的是**仓库里的源文件**，
/// 不是任何副本（对位 Android `DiagTextTest` 从 user.dir 往上找仓库根）。
enum RepoPaths {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // PPassTests
        .deletingLastPathComponent() // ios
        .deletingLastPathComponent() // apps
        .deletingLastPathComponent() // 仓库根
}
