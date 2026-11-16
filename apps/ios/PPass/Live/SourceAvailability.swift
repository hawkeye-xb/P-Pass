import PPassCore

struct SourceAvailability: Equatable, Sendable {
    let autoRule: Bool
    let photoAccess: MediaAccess
    let hasUsableFolder: Bool
    let hasSelectedAlbum: Bool

    var folderOnly: Bool { hasUsableFolder && !hasSelectedAlbum }
    var showsGlobalPhotoBlock: Bool { autoRule && photoAccess != .full && !hasUsableFolder }
    /// 没有照片权限时，folder-only 仍在备份目录，不显示相册-only 的停止提示。
    var showsDeniedPhotoHint: Bool { photoAccess == .none && !folderOnly }
    /// 仅相册-only 的部分授权需要引导去系统设置申请完整权限。
    var needsFullPhotoAccessSettings: Bool { photoAccess == .partial && !folderOnly }

    static func hasUsableFolder(selected: Set<String>?, known: Set<String>, folderCount: Int) -> Bool {
        if selected?.contains(where: { $0.hasPrefix("folder:") }) == true { return true }
        let unified = known.union(selected ?? []).contains { $0.hasPrefix("folder:") }
        return !unified && folderCount > 0
    }
}
