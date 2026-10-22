import Foundation

/// 从相册取一张照片的原始字节，写到临时文件（IOS-11，对齐 #311 D4 / Immich 的做法）。
///
/// 流程：解析原图资源 → 在 ``tempRoot`` 下为这一次读取建一个独立目录 → 流式写入 → 交给调用方（算哈希、导入 iroh store）
/// → 调用方用完后 ``FetchedOriginal/discard()``。
///
/// 清理保证：
/// - 任何失败（网络、空间、资源不可得、取消）都会在抛出之前删掉这次的目录，不留半截文件。
/// - ``FetchedOriginal`` 被释放时也会删（兜底，防止调用方忘了 discard）。
/// - 进程崩溃时留下的目录，由下一轮开始时调用 ``purgeLeftovers()`` 清掉。
public final class OriginalFetcher: @unchecked Sendable {
    public let tempRoot: URL
    private let source: OriginalResourceSource

    /// - Parameter tempRoot: 临时目录根。默认放在 App 的 tmp 下；**只能**给本类专用，``purgeLeftovers()`` 会清空它。
    public init(source: OriginalResourceSource = PhotoKitOriginalSource(),
                tempRoot: URL = FileManager.default.temporaryDirectory.appendingPathComponent("ppass-originals", isDirectory: true)) {
        self.source = source
        self.tempRoot = tempRoot
    }

    /// 清掉上一轮（或崩溃）留下的临时文件。每个备份轮开始时调用一次；本轮还在用的 ``FetchedOriginal`` 不能和它并发。
    public func purgeLeftovers() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: tempRoot, includingPropertiesForKeys: nil) else { return }
        for entry in entries { try? fm.removeItem(at: entry) }
    }

    /// 取原图到临时文件。
    ///
    /// - Parameter onLocality: 开始读之前判定一次原图在不在本机（true = 在本机；false = 要从 iCloud 下载）；判断不了不调用。
    /// - Throws: ``OriginalFetchFailure``（分类见其文档）；Task 被取消时抛 `CancellationError`。
    public func fetch(assetId: String, progress: @escaping @Sendable (Double) -> Void = { _ in },
                      onLocality: @escaping @Sendable (Bool) -> Void = { _ in }) async throws -> FetchedOriginal {
        try Task.checkCancellation()
        let info = try source.resolveOriginal(assetId: assetId)
        if let local = await source.isLocal(info) { onLocality(local) }
        try Task.checkCancellation()
        let fm = FileManager.default
        let dir = tempRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let ext = (info.originalFilename as NSString).pathExtension
        let file = dir.appendingPathComponent(ext.isEmpty ? "original" : "original.\(ext)")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            guard fm.createFile(atPath: file.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
            }
            let handle = try FileHandle(forWritingTo: file)
            var written: Int64 = 0
            do {
                try await source.streamData(of: info, progress: progress) { data in
                    try handle.write(contentsOf: data)
                    written += Int64(data.count)
                }
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            try Task.checkCancellation()
            return FetchedOriginal(info: info, fileURL: file, directory: dir, sizeBytes: written)
        } catch {
            try? fm.removeItem(at: dir)
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let failure = error as? OriginalFetchFailure { throw failure }
            if OriginalFetchErrorClassifier.isUserCancelled(error) { throw CancellationError() }
            throw OriginalFetchErrorClassifier.classify(error)
        }
    }

    /// 取原图并用注入的哈希函数算内容哈希。哈希失败时临时文件同样会被删掉。
    ///
    /// `hashFile` 生产上是 XCFramework 导出的 BLAKE3（PPassCore `ContentHasher.blake3Hex(ofFileAt:)`，它对文件流式计算）。
    /// 本包不实现 BLAKE3。
    public func fetchAndHash(
        assetId: String,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        hashFile: (URL) throws -> String
    ) async throws -> (original: FetchedOriginal, contentHash: String) {
        let original = try await fetch(assetId: assetId, progress: progress)
        do {
            return (original, try hashFile(original.fileURL))
        } catch {
            original.discard()
            throw error
        }
    }
}

/// 一次读取的结果：临时文件及其元数据。用完调用 ``discard()``；忘了调用时，对象释放时也会删。
public final class FetchedOriginal: @unchecked Sendable {
    public let info: OriginalResourceInfo
    public let fileURL: URL
    public let sizeBytes: Int64
    private let directory: URL
    private let lock = NSLock()
    private var discarded = false

    init(info: OriginalResourceInfo, fileURL: URL, directory: URL, sizeBytes: Int64) {
        self.info = info
        self.fileURL = fileURL
        self.directory = directory
        self.sizeBytes = sizeBytes
    }

    /// 删掉临时文件。可重复调用。
    public func discard() {
        lock.lock()
        defer { lock.unlock() }
        guard !discarded else { return }
        discarded = true
        try? FileManager.default.removeItem(at: directory)
    }

    deinit { discard() }
}
