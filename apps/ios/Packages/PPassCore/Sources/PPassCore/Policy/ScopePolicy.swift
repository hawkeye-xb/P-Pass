// 相册范围语义（#983），逐条对位 Android，不另起口径。
import Foundation

public enum ScopePolicy {
    /// 这次保存相对上次**新增**的相册（MainActivity：`if (prevScope == null) sel else sel - prevScope`）。
    /// 非空才触发 SCOPE_ADDED；减少相册或原样保存不触发。previous == nil = 从未保存过范围，选了的全算新增。
    public static func added(previous: Set<String>?, selected: Set<String>) -> Set<String> {
        guard let previous else { return selected }
        return selected.subtracting(previous)
    }

    /// 「已选相册」计数（HomeScreen `selectedExistingCount`，#836）：已选且当前存在。
    /// existing == nil = 读不到相册（无完整授权），无从判断哪些还在，沿用已选个数；selected == nil = 从未保存。
    public static func selectedExistingCount(selected: Set<String>?, existing: Set<String>?) -> Int? {
        guard let selected else { return nil }
        guard let existing else { return selected.count }
        return selected.intersection(existing).count
    }
}
