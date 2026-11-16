import PPassCore

struct SourceAvailability: Equatable, Sendable {
    let autoRule: Bool
    let photoAccess: MediaAccess
    let hasUsableFolder: Bool
    let hasSelectedAlbum: Bool

    var folderOnly: Bool { hasUsableFolder && !hasSelectedAlbum }
    var showsGlobalPhotoBlock: Bool { autoRule && photoAccess != .full && !hasUsableFolder }

    static func hasUsableFolder(selected: Set<String>?, known: Set<String>, folderCount: Int) -> Bool {
        if selected?.contains(where: { $0.hasPrefix("folder:") }) == true { return true }
        let unified = known.union(selected ?? []).contains { $0.hasPrefix("folder:") }
        return !unified && folderCount > 0
    }
}
