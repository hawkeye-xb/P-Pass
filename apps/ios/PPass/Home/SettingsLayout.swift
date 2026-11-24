enum SettingsLayout {
    enum Group: Hashable { case backup, selection, conditions }
    enum Backup: Hashable { case rule, scope, background }
    enum Condition: Hashable { case wifi, notifications, more }

    enum Selection: Hashable {
        case photos, files

        var labelKey: String {
            switch self {
            case .photos: "pick_from_photos_label"
            case .files: "pick_from_files_label"
            }
        }

        var accessibilityID: String {
            switch self {
            case .photos: "pickPhotosRow"
            case .files: "pickFilesRow"
            }
        }

        func request(photos: () -> Void, files: () -> Void) {
            switch self {
            case .photos: photos()
            case .files: files()
            }
        }

        func listRow(action: @escaping () -> Void) -> SingleTransferSelectionRow {
            SingleTransferSelectionRow(title: L.s(labelKey), inList: true, action: action)
        }
    }

    static let sections: [Group] = [.backup, .selection, .conditions]
    static let selectionRows: [Selection] = [.photos, .files]
    static let conditionRows: [Condition] = [.wifi, .notifications, .more]

    static func backupRows(autoRule: Bool) -> [Backup] {
        autoRule ? [.rule, .scope, .background] : [.rule]
    }
}
