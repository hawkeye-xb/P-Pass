import SwiftUI

@main
struct PPassApp: App {
    @StateObject private var app = AppModel(backend: AppBackend.make())

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                // 系统默认 tint 是蓝色：根上统一换成墨色，按钮 / 开关 / 进度条不会冒出库色（#344）。
                .tint(PPColor.ink)
        }
    }
}

/// 选哪套端口实现。壳阶段只有演示数据；集成后真实现是默认，`PPASS_SCENARIO` 显式要求时才用演示数据。
enum AppBackend {
    static func make() -> Backend { FakeBackend.make() }
}
