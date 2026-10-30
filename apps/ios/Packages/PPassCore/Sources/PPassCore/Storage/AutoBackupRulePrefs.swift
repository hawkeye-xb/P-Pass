// #1272 B：「自动备份」规则开关（与 `AutoBackupPrefs` 的「App 关着也传」是两件事）。对位 Android AutoBackupRulePrefs.kt。
// 没存过值时，按当前真实状态初始化一次并落盘（读现状，不是迁移）：有完全访问权限且已选过备份范围 ⇒ 开，否则 ⇒ 关；
// 之后以存下的值为准。权限被收回时偏好不动（界面单独显示成「已停止」）。
import Foundation

public final class AutoBackupRulePrefs: @unchecked Sendable {
    public static let fileName = "auto_backup_rule.json"
    private let url: URL
    private let logger: CoreLogger

    public init(directory: URL, logger: CoreLogger = NoopLogger()) {
        url = directory.appendingPathComponent(Self.fileName)
        self.logger = logger
    }

    /// 存下的值；从未存过（或文件损坏）= nil。
    public func stored() -> Bool? {
        JSONFile.lock.lock(); defer { JSONFile.lock.unlock() }
        return JSONFile.readObject(url, logger: logger)?.bool("enabled")
    }

    /// 没存过值才用 [current] 初始化并落盘；已有值不被覆盖。返回生效的值。
    @discardableResult
    public func initIfAbsent(current: Bool) -> Bool {
        if let v = stored() { return v }
        try? set(current)
        return current
    }

    public func set(_ enabled: Bool) throws {
        JSONFile.lock.lock(); defer { JSONFile.lock.unlock() }
        try JSONFile.write(["enabled": enabled], url)
    }
}
