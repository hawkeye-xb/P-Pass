// #955：日志落盘。NSLog 在后台拉起（BGTask / 静默唤醒）时没有任何可取回的落点，这里把同一行写进容器内的滚动文件，
// 开发机用 `devicectl device copy from` 取回。
//
// 约束：
// - 线程安全且不阻塞调用方：调用方只入队，格式化与写盘都在一条串行队列上。
// - 写失败一律吞掉（日志不能拖垮业务），下一行重试。
// - 单文件上限 [maxBytes]，超过就把 ppass.log 换成 ppass.log.1（只保留这 2 份），总占用 ≤ 2 × maxBytes。
// - 文件保护取 completeUntilFirstUserAuthentication：手机锁屏时被 BGTask 拉起也写得进去（默认的 complete 会写失败）。
import Foundation

public final class RollingFileLog: @unchecked Sendable {
    public static let defaultMaxBytes = 1_000_000

    private let url: URL
    private let archive: URL
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "ppass.rolling-file-log", qos: .utility)
    // 以下只在 queue 上访问。
    private var handle: FileHandle?
    private var size = 0
    private let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()

    public init(url: URL, maxBytes: Int = RollingFileLog.defaultMaxBytes) {
        self.url = url
        self.archive = url.appendingPathExtension("1")
        self.maxBytes = max(256, maxBytes)
    }

    /// 入队即返回。行内换行折成空格，一行日志 = 文件里一行。
    public func write(_ message: String, at date: Date = Date()) {
        queue.async { [self] in append(message, date) }
    }

    /// 等队列里已入的行都落盘（测试用；产品路径不需要）。
    public func flush() { queue.sync {} }

    private func append(_ message: String, _ date: Date) {
        let flat = message.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        var data = Data("\(stamp.string(from: date)) \(flat)\n".utf8)
        if data.count > maxBytes { data = data.prefix(maxBytes - 1) + Data("\n".utf8) }
        do {
            let h = try open()
            if size > 0, size + data.count > maxBytes {
                try roll()
                try write(data, try open())
            } else {
                try write(data, h)
            }
        } catch {
            // 吞掉：丢掉句柄，下一行重新打开。
            try? handle?.close()
            handle = nil
        }
    }

    private func write(_ data: Data, _ h: FileHandle) throws {
        try h.write(contentsOf: data)
        size += data.count
    }

    private func open() throws -> FileHandle {
        if let handle { return handle }
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: protection)
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil, attributes: protection) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let h = try FileHandle(forWritingTo: url)
        let end = try h.seekToEnd()
        size = Int(end)
        handle = h
        return h
    }

    private func roll() throws {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        try? fm.removeItem(at: archive)
        try fm.moveItem(at: url, to: archive)
        size = 0
    }
}

/// 日志隐私口径（与 Android 一致）：不写照片文件名、相册名、凭据，只写 hash 前缀与计数。
public enum LogRedact {
    /// 标识（PHAsset localIdentifier 等）→ 8 位 hash 前缀。同一标识同一前缀，能对账，不能反查。
    public static func id(_ raw: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325 // FNV-1a
        for b in raw.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        let hex = String(h, radix: 16)
        return String((String(repeating: "0", count: 16 - hex.count) + hex).prefix(8))
    }

    private static let mediaFileName = try! NSRegularExpression(
        pattern: #"[^\s/\\"'()]+\.(heic|heif|jpe?g|png|gif|webp|dng|raw|tiff?|mov|mp4|m4v|avi)\b"#, options: [.caseInsensitive])
    private static let longToken = try! NSRegularExpression(pattern: #"[A-Za-z0-9+/_=-]{32,}"#)

    /// 落盘前的兜底：错误描述（`\(error)`）里可能夹带媒体文件名、blob ticket / token（≥32 字符的连续串）。
    /// 文件名换成 `<file>`，长串只留 6 位前缀。
    public static func scrub(_ line: String) -> String {
        var s = line
        s = replace(mediaFileName, in: s) { _ in "<file>" }
        s = replace(longToken, in: s) { "\($0.prefix(6))…(\($0.count))" }
        return s
    }

    private static func replace(_ re: NSRegularExpression, in s: String, _ f: (String) -> String) -> String {
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += f(ns.substring(with: m.range))
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }
}
