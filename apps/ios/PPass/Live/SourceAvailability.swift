import PPassCore

/// #1811 统一口径（简单版）：当前有没有可用来源、是否在传。通知、首页状态卡与按钮都读这一份，
/// 不改 pending 队列、订单状态与单张传输状态机。
struct BackupAvailability: Equatable, Sendable {
    let hasUsableSource: Bool
    let isTransferring: Bool

    /// 备份确实在继续：有可用来源并且在传。此时不能说「自动备份已停止」。
    var isBackingUp: Bool { hasUsableSource && isTransferring }
}

struct SourceAvailability: Equatable, Sendable {
    let autoRule: Bool
    let photoAccess: MediaAccess
    let hasUsableFolder: Bool
    let hasSelectedAlbum: Bool

    var folderOnly: Bool { hasUsableFolder && !hasSelectedAlbum }
    /// #1811 统一口径的一半：有没有能继续备份的来源——目录可用，或完整授权下已选且存在的相册。
    /// 有限 / 拒绝授权时相册不算来源（那几张只走「挑几张传」），文件夹照常。
    var hasUsableSource: Bool { hasUsableFolder || (photoAccess == .full && hasSelectedAlbum) }

    /// 纯相册范围、照片权限未完整：自动备份真的停了，出停止状态并带「去设置」。
    /// #1788 同判据同步债（归 #1789 接线时处理，对齐 Android `SourceAvailability`）：空范围缺的是
    /// **来源**不是权限，去设置授权也不会添加来源——只有真的选了相册才报这条。
    var showsGlobalPhotoBlock: Bool { autoRule && photoAccess != .full && !hasUsableFolder && hasSelectedAlbum }
    /// 目录 + 相册混合、照片权限未完整：文件夹还在传，只把相册侧说成「未完整授权」并给「调整范围」出口。
    var mixedAlbumIncomplete: Bool { autoRule && photoAccess != .full && hasUsableFolder && hasSelectedAlbum }
    /// 没有照片权限时，仍有目录来源（folder-only / 混合）不显示相册-only 的停止提示。
    var showsDeniedPhotoHint: Bool { photoAccess == .none && !hasUsableFolder }
    /// 仅没有可用目录来源的部分授权才需要引导去系统设置申请完整权限。
    var needsFullPhotoAccessSettings: Bool { photoAccess == .partial && !hasUsableFolder }

    static func hasUsableFolder(selected: Set<String>?, known: Set<String>, folderCount: Int) -> Bool {
        if selected?.contains(where: { $0.hasPrefix("folder:") }) == true { return true }
        let unified = known.union(selected ?? []).contains { $0.hasPrefix("folder:") }
        return !unified && folderCount > 0
    }

    /// 通知侧（`DefinitiveFacts`）与页面同一份口径：有可用来源时，「自动备份已停止」是假话。
    static func usableSource(selected: Set<String>?, known: Set<String>, folderCount: Int,
                             existingAlbums: Set<String>?, photoAccess: MediaAccess) -> Bool {
        if hasUsableFolder(selected: selected, known: known, folderCount: folderCount) { return true }
        guard photoAccess == .full else { return false }
        let albumScope = selected.map { $0.filter { !$0.hasPrefix("folder:") } }
        return (ScopePolicy.selectedExistingCount(selected: albumScope, existing: existingAlbums) ?? 0) > 0
    }
}
