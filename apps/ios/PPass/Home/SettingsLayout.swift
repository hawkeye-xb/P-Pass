enum SettingsLayout {
    enum Group: Hashable {
        case backup, selection, conditions

        var headerKey: String? {
            switch self {
            case .backup: nil
            case .selection: "settings_section_single_transfer"
            case .conditions: "settings_section_preferences"
            }
        }
    }
    enum Backup: Hashable {
        case rule, scope, background

        /// 该行对应的二级路由；没有二级页的行（开关）返回 nil。
        var route: SettingsScreen.Route? { self == .scope ? .bucket : nil }
    }
    enum Condition: Hashable {
        case wifi, notifications, more

        /// 该行对应的二级路由；开关行返回 nil。
        var route: SettingsScreen.Route? { self == .more ? .more : nil }
    }

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
    }

    static let sections: [Group] = [.backup, .selection, .conditions]
    static let selectionRows: [Selection] = [.photos, .files]
    static let conditionRows: [Condition] = [.wifi, .notifications, .more]

    static func backupRows(autoRule: Bool) -> [Backup] {
        autoRule ? [.rule, .scope, .background] : [.rule]
    }
}
