import Foundation

/// 调试用的启动入口（截图 / 模拟器端到端传入的 `PPASS_ROUTE`、`PPASS_PAIR_CODE`）。
/// 只在 DEBUG 构建里生效：Release 包不读这两个键，环境变量与 UserDefaults 两个来源都一样（#1152）——
/// 否则别的进程 / 描述文件 / 备份恢复出来的 UserDefaults 都能把一个配对串或起始屏塞给正式包。
enum DebugLaunchInput {
    /// 当前是不是 DEBUG 构建。测试用 `enabled:` 参数覆盖，不靠编译开关。
    static let isDebugBuild: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    /// 环境变量优先，其次（`fromDefaults`）UserDefaults；非 DEBUG 一律 nil。空串当没传。
    static func value(_ key: String, fromDefaults: Bool = false, enabled: Bool = isDebugBuild,
                      environment: [String: String] = ProcessInfo.processInfo.environment,
                      defaults: UserDefaults = .standard) -> String? {
        guard enabled else { return nil }
        let raw = environment[key] ?? (fromDefaults ? defaults.string(forKey: key) : nil)
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    static var route: String? { value("PPASS_ROUTE", fromDefaults: true) }
    static var pairCode: String? { value("PPASS_PAIR_CODE") }
}
