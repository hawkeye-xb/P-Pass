// 「保存到相册」去重记录：内容哈希 → 相册里那张的 localIdentifier（#1152）。
// 之前放 UserDefaults（`ppass.saved_to_gallery`）：断开配对清不掉，也会随 iCloud / Finder 备份走。
// 现在是存储根下的一个文件：存储根整个不进备份（localIdentifier 只在本机相册库里有意义，恢复到别的手机上没用），
// 断开时由 [DisconnectState.savedToGallery] 清掉（哪些照片存过相册，是这台电脑相册的痕迹）。
import Foundation

public struct SavedToGalleryStore: Sendable {
    public static let fileName = "saved_to_gallery.json"
    /// 旧版本的 UserDefaults 键：启动时删一次，不迁移（iOS 未宣发，全是测试机）。
    public static let legacyDefaultsKey = "ppass.saved_to_gallery"

    private let url: URL
    private let logger: CoreLogger

    public init(directory: URL, logger: CoreLogger = NoopLogger()) {
        self.url = directory.appendingPathComponent(Self.fileName)
        self.logger = logger
    }

    public func localIdentifier(for hash: String) -> String? {
        JSONFile.lock.lock(); defer { JSONFile.lock.unlock() }
        return JSONFile.read([String: String].self, url, logger: logger)?[hash]
    }

    public func remember(hash: String, localIdentifier: String) throws {
        JSONFile.lock.lock(); defer { JSONFile.lock.unlock() }
        var map = JSONFile.read([String: String].self, url, logger: logger) ?? [:]
        map[hash] = localIdentifier
        try JSONFile.write(map, url)
    }

    /// 删旧版本留在 UserDefaults 里的那份。
    public static func removeLegacyDefaults(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: legacyDefaultsKey)
    }
}
