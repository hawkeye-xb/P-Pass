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

/// 备份范围的时间一档（#1263）：只有「从今天起」和「全部」两档，不做自选日期。
/// 「从今天起」存的是**绝对时刻**（选定那天的零点，unix ms），不是每次求值时现算的「今天」——否则窗口每天往后滑，
/// 昨天还没传完的会被踢出范围。
///
/// iOS 偏离（登记在 tokens.json platforms.ios）：时间按 `PHAsset.creationDate`（拍摄时间）算；Android 按 `DATE_ADDED`
/// （进入手机相册的时间）。PhotoKit 没有公开的「加入图库时间」，所以「今天才存进手机的老照片」Android 算新的，iOS 算以前的。
public enum BackupSince: Equatable, Sendable {
    case all
    case since(ms: Int64)

    public var isAll: Bool { self == .all }
}

extension ScopePolicy {
    /// 保存时落盘的时间档。选「全部」→ 全部；选「从今天起」且之前已经是「从今天起」→ 锚点不动（编辑相册不该把起点往后挪）；
    /// 其余（首次保存 / 从「全部」改回来）→ 当天零点（#1263：「今天」从零点算，今天已经拍的照片也算）。
    public static func sinceForSave(previous: BackupSince?, wantsAll: Bool, now: Date, calendar: Calendar = .current) -> BackupSince {
        if wantsAll { return .all }
        if case .since(let ms)? = previous { return .since(ms: ms) }
        return .since(ms: Int64(calendar.startOfDay(for: now).timeIntervalSince1970 * 1000))
    }

    /// 时间档有没有**放宽**（「从今天起 → 全部」或起点提前）：放宽就和新增相册一样走 SCOPE_ADDED 补扫。
    /// previous == nil = 从未保存过（新增相册那条已经会触发），这里不重复算。
    public static func widened(previous: BackupSince?, next: BackupSince) -> Bool {
        guard case .since(let old)? = previous else { return false }
        switch next {
        case .all: return true
        case .since(let new): return new < old
        }
    }

    /// 选范围页一进来时间档是不是「全部」（对位 Android `initialScopeTime`）：保存过 → 回显；没保存过、只给了部分照片 →
    /// 「全部」（10-30：只挑了几张就是想传它们，多半是以前的照片）；没保存过、完整访问 →「从今天起」。
    public static func initialWantsAll(saved: BackupSince?, partialAccess: Bool) -> Bool {
        if let saved { return saved.isAll }
        return partialAccess
    }

    /// 选范围页的初始勾选：从未保存过 → 默认勾上「最近项目」（iOS 上相机拍的照片只在这里，对位 Android 的相机相册，#1263）；
    /// 保存过 → 已保存且当前还在的（新相册默认不勾，MOB-02）。
    public static func initialSelection(saved: Set<String>?, available: Set<String>, cameraAlbum: String?) -> Set<String> {
        guard let saved else { return cameraAlbum.map { available.contains($0) ? [$0] : [] } ?? [] }
        return saved.intersection(available)
    }
}

/// 范围键（`MediaSnapshot.bucketId` / `Order.bucketId`）的 iOS 编码：媒体源定义、引擎只经注入的 `inScope` 解释（FlowTypes）。
/// 内容 = 可选的拍摄时刻一行 `t:<unix ms>` + 所属相册 id 每行一个。时间编在键里，是为了让已经落库的 order 也能按时间档判断
/// （改回「从今天起」后，没传的以前的照片不再传）。没有时间行（拍摄时间未知 / #1263 之前建的行）在「从今天起」下算范围外。
public enum ScopeKey {
    static let timePrefix = "t:"

    public static func encode(albums: [String], capturedAtMs: Int64?) -> String {
        let lines = (capturedAtMs.map { ["\(timePrefix)\($0)"] } ?? []) + albums
        return lines.joined(separator: "\n")
    }

    public static func decode(_ key: String) -> (albums: [String], capturedAtMs: Int64?) {
        var albums: [String] = []
        var captured: Int64?
        for line in key.split(separator: "\n").map(String.init) {
            if line.hasPrefix(timePrefix), let ms = Int64(line.dropFirst(timePrefix.count)) { captured = ms } else { albums.append(line) }
        }
        return (albums, captured)
    }

    /// 时间档单独判断（发现路径上相册已经筛过，只差时间）。
    public static func inTime(capturedAtMs: Int64?, since: BackupSince) -> Bool {
        switch since {
        case .all: return true
        case .since(let start): return capturedAtMs.map { $0 >= start } ?? false
        }
    }

    /// 范围 = 任一所属相册被选中 **且** 时间档内。
    public static func inScope(_ key: String, selected: Set<String>, since: BackupSince) -> Bool {
        let (albums, captured) = decode(key)
        return !selected.isDisjoint(with: albums) && inTime(capturedAtMs: captured, since: since)
    }
}
