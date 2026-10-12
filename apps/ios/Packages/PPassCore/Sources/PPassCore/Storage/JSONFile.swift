// 小 JSON 文件的读写（对位 Android 各 store 的 `tmp + rename`）：
//   - 写：`Data.write(options: .atomic)` = 唯一临时文件 + rename（MOB-102 的教训：固定 `.tmp` 名两个写者会互相踩）；
//   - 读：文件不在 → 默认值；读出来解不开（损坏 / 半截）→ 默认值，**并记一行日志**（Android 静默 getOrDefault，
//     值的语义一致；多记一行是为了不静默）。
// 同一进程里所有 JSON store 共用一把锁：读-改-写不交错（#540 的教训：两个线程写同一份文件）。
import Foundation

enum JSONFile {
    static let lock = NSRecursiveLock()

    /// 读出原始 JSON 对象（store 自己解字段，便于兼容旧键）。nil = 文件不在或损坏。
    static func readObject(_ url: URL, logger: CoreLogger) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                logger.log("storage: \(url.lastPathComponent) is not a JSON object; using defaults")
                return nil
            }
            return object
        } catch {
            logger.log("storage: \(url.lastPathComponent) unreadable (\(error.localizedDescription)); using defaults")
            return nil
        }
    }

    static func read<T: Decodable>(_ type: T.Type, _ url: URL, logger: CoreLogger) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
        } catch {
            logger.log("storage: \(url.lastPathComponent) unreadable (\(error)); using defaults")
            return nil
        }
    }

    static func write<T: Encodable>(_ value: T, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

/// Android `JSONObject` 风格的取值：类型不对按「没有这个键」处理（kotlinx `booleanOrNull` 的对位）。
extension Dictionary where Key == String, Value == Any {
    func bool(_ key: String) -> Bool? {
        guard let n = self[key] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }
}
