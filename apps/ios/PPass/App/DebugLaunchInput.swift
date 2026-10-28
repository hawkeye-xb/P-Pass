import Foundation

/// 调试用的启动入口（截图 / 模拟器端到端传入的 `PPASS_*`）。
/// 只在 DEBUG 构建里生效：Release 包不读这些键，环境变量与 UserDefaults 两个来源都一样（#1152、#1227）——
/// 否则别的进程 / 描述文件 / 备份恢复出来的 UserDefaults 都能把一个配对串、演示场景或身份破坏开关塞给正式包。
/// 门禁：`DebugLaunchInputTests.test_only_the_gate_reads_ppass_keys` 扫源码，`"PPASS_…"` 字面量只许出现在本文件
/// 和整文件包在 `#if DEBUG` 里的 `PPass/Debug/*.swift`；新加入口走这里，否则门禁红。
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

    /// 经本文件门控的全部键。新加入口要登记在这里（门禁测试核对：本文件里出现的每个 `"PPASS_…"` 字面量都得在列表里）。
    static let gatedKeys = [
        "PPASS_ROUTE", "PPASS_PAIR_CODE", "PPASS_SCENARIO", "PPASS_DEMO_FLIP_MINE", "PPASS_DEMO_PHOTOS",
        "PPASS_VIEWER_ITEM", "PPASS_E2E_RESET", "PPASS_DEBUG_DROP_IDENTITY", "PPASS_DEBUG_IDENTITY_FAIL",
    ]

    static var route: String? { value("PPASS_ROUTE", fromDefaults: true) }
    static var pairCode: String? { value("PPASS_PAIR_CODE") }
    /// 演示场景（FakeScenario 的 rawValue）；env 与 UserDefaults 都读。
    static var scenario: String? { value("PPASS_SCENARIO", fromDefaults: true) }
    /// 商店截图：「本机 / 家人」对调。
    static var demoFlipMine: Bool { value("PPASS_DEMO_FLIP_MINE") == "1" }
    /// 商店截图：演示照片目录。
    static var demoPhotosDir: String? { value("PPASS_DEMO_PHOTOS") }
    /// 商店截图：自动打开时间线第几条。
    static var viewerItem: Int? { value("PPASS_VIEWER_ITEM").flatMap { Int($0) } }
    /// 启动前清存储根与钥匙串身份。
    static var e2eReset: Bool { value("PPASS_E2E_RESET") == "1" }
    /// 只删钥匙串里的身份。
    static var dropIdentity: Bool { value("PPASS_DEBUG_DROP_IDENTITY") == "1" }
    /// 钥匙串读失败（看拒绝启动页用）。
    static var identityFail: Bool { value("PPASS_DEBUG_IDENTITY_FAIL") == "1" }
}
