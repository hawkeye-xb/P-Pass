// #1731 本地授权目录来源：来源与文件映射的注册表（ADR §2 SourceRegistry）。
// 保存 sourceId、显示名、目录书签、授权状态与 opaque itemId ↔ 相对路径的私有映射，跨启动恢复。
// 目录书签与完整相对路径只放在这里（App 私有容器）：不写日志、不进 order、不进审计 itemRef、不上协议。
import Foundation
import PPassCore

struct FolderSourceError: Error {
    let reason: String
}

/// 一个已登记的目录来源（持久化形状）。
struct FolderRecord: Codable, Equatable {
    /// 稳定 UUID；移除后不复用（`FolderRegistry.removedIds` 防复用）。
    var id: String
    var displayName: String
    /// 目录书签（用户经目录选择器授权时生成；测试里是普通目录的 bookmark，同样可解析）。
    var bookmark: Data
    /// 登记成功 = registered；书签 stale 重建失败 = recoveryUnverified（旧书签保留，恢复未验证）。
    var status: String
    /// opaque itemId ↔ 相对路径（键 = opaqueId，值 = 规范化相对路径，`/` 分隔、不含 `.` / `..` 段）。
    var items: [String: String]

    init(id: String, displayName: String, bookmark: Data, status: String = "registered", items: [String: String] = [:]) {
        self.id = id
        self.displayName = displayName
        self.bookmark = bookmark
        self.status = status
        self.items = items
    }
}

/// 解析后的根目录：URL + 记录（可能已换成重建后的书签）。
struct FolderRoot {
    let url: URL
    let record: FolderRecord
}

enum FolderBookmarks {
    /// 解析书签 → 根目录。stale 且根仍可用时在当前授权内重建并原子替换；替换失败保留旧书签并记恢复未验证。
    /// 书签不存在 / 损坏 / 解析失败 → 抛 `FolderSourceError`（调用方桥接成 `SourceUnavailable`）。
    /// 根可达性检查留给调用方在 scope 内做（真机 security scope 下 scope 外查不到）。
    /// `forceStale` 只为测试注入 stale 判定（产品路径由系统给出）。
    static func resolve(_ record: FolderRecord, registry: FolderRegistry, logger: CoreLogger, forceStale: Bool = false) throws -> FolderRoot {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: record.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            throw FolderSourceError(reason: "bookmark unreadable")
        }
        if forceStale { stale = true }
        var updated = record
        if stale {
            // 重建必须在当前授权内做：start 一次（普通目录 start=false，文件在就当授权在）。
            let opened = url.startAccessingSecurityScopedResource()
            defer { if opened { url.stopAccessingSecurityScopedResource() } }
            let accessible = opened || FileManager.default.fileExists(atPath: url.path)
            if accessible, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                updated.bookmark = fresh
                updated.status = "registered"
                registry.upsert(updated)
                logger.log("folder \(record.id): stale bookmark rebuilt and replaced atomically")
            } else {
                // 替换失败：保留旧书签，记恢复未验证，不能先毁掉旧书签。
                updated.status = "recoveryUnverified"
                registry.upsert(updated)
                logger.log("folder \(record.id): stale bookmark rebuild failed; old bookmark kept, recovery unverified")
            }
        }
        return FolderRoot(url: url, record: updated)
    }

    /// 在根授权内跑一段读取（start/stop 严格配对；普通目录 start=false 也成对）。body 可以 async（导入要 await FFI）。
    static func withScope<T>(_ url: URL, _ body: (URL) async throws -> T) async throws -> T {
        let opened = url.startAccessingSecurityScopedResource()
        defer { if opened { url.stopAccessingSecurityScopedResource() } }
        return try await body(url)
    }
}

/// 相对路径的语法规范化（ADR §3）：分隔符与 `.` 段处理，拒绝绝对路径和 `..`；不折叠 Unicode、不判等大小写。
enum FolderPaths {
    static func normalize(_ raw: String) throws -> String {
        guard !raw.hasPrefix("/") else { throw FolderSourceError(reason: "absolute path rejected") }
        var parts: [String] = []
        for part in raw.split(separator: "/", omittingEmptySubsequences: true) {
            let p = String(part)
            if p == "." { continue }
            if p == ".." { throw FolderSourceError(reason: "parent segment rejected") }
            parts.append(p)
        }
        guard !parts.isEmpty else { throw FolderSourceError(reason: "empty path") }
        return parts.joined(separator: "/")
    }

    /// `String` 比较会把 `"é"` 与 `"e\u{0301}"` 判等；路径判等按字节（与 mediaId 判等同一口径）。
    static func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
}

/// 来源注册表：App 私有 JSON（单文件、原子写）。一个进程一个实例；跨启动恢复靠重读文件。
final class FolderRegistry: @unchecked Sendable {
    private let fileURL: URL
    private let logger: CoreLogger
    private let lock = NSLock()
    private var sources: [String: FolderRecord]
    private var removedIds: Set<String>

    /// - Parameter directory: 持久化目录（App 私有容器；测试里用临时目录）。
    init(directory: URL, logger: CoreLogger) {
        fileURL = directory.appendingPathComponent("folder-sources.json")
        self.logger = logger
        let json = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(Persisted.self, from: $0) }
        sources = json?.sources ?? [:]
        removedIds = Set(json?.removedIds ?? [])
    }

    private struct Persisted: Codable {
        var sources: [String: FolderRecord]
        var removedIds: [String]
        init(sources: [String: FolderRecord], removedIds: Set<String>) {
            self.sources = sources
            self.removedIds = removedIds.sorted()
        }
    }

    @discardableResult
    private func persistLocked() -> Bool {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(Persisted(sources: sources, removedIds: removedIds)).write(to: fileURL, options: .atomic)
            return true
        } catch {
            // 写失败上报（同类 PairingStore.save 也是 throws）：调用方决定要不要当作成功。
            logger.log("folder registry: persist failed (\(error.localizedDescription))")
            return false
        }
    }

    func upsert(_ record: FolderRecord) {
        lock.lock(); defer { lock.unlock() }
        sources[record.id] = record
        persistLocked()
    }

    func record(id: String) -> FolderRecord? {
        lock.lock(); defer { lock.unlock() }
        return sources[id]
    }

    func allRecords() -> [FolderRecord] {
        lock.lock(); defer { lock.unlock() }
        return sources.values.sorted { $0.id < $1.id }
    }

    /// 登记一个目录来源：生成书签，书签生成失败就抛错、不启用该来源（ADR「书签保存失败：不启用该来源」）。
    @discardableResult
    func addFolder(at url: URL, displayName: String) throws -> String {
        let bookmark: Data
        do {
            bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            logger.log("folder registry: bookmark creation failed for \(displayName): \(error.localizedDescription)")
            throw FolderSourceError(reason: "bookmark creation failed")
        }
        lock.lock()
        let id = UUID().uuidString.lowercased()
        sources[id] = FolderRecord(id: id, displayName: displayName, bookmark: bookmark)
        let persisted = persistLocked()
        if !persisted {
            // ADR「书签保存失败：不启用该来源，向调用方报错，不假装登记成功」——撤销内存登记再抛。
            sources.removeValue(forKey: id)
            lock.unlock()
            throw FolderSourceError(reason: "bookmark save failed")
        }
        lock.unlock()
        return id
    }

    /// 移除来源：id 进 removedIds，永不复用。
    func removeFolder(id: String) {
        lock.lock(); defer { lock.unlock() }
        _ = sources.removeValue(forKey: id)
        removedIds.insert(id)
        persistLocked()
    }

    func isKnownOrRemoved(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sources[id] != nil || removedIds.contains(id)
    }

    /// 相对路径 → 现有 opaque itemId（没有则分配一个并持久化）。opaqueId 不含相对路径。
    func opaqueId(sourceId: String, relativePath: String) -> String {
        lock.lock(); defer { lock.unlock() }
        if let record = sources[sourceId] {
            for (opaque, path) in record.items where FolderPaths.same(path, relativePath) {
                return opaque
            }
        }
        let opaque = UUID().uuidString.lowercased()
        if var record = sources[sourceId] {
            record.items[opaque] = relativePath
            sources[sourceId] = record
            persistLocked()
        }
        return opaque
    }

    /// opaque itemId → 相对路径（导入时按映射找到文件）。损坏的持久化文件若带越界路径，这里拒绝（返回 nil 不导入）。
    func relativePath(sourceId: String, opaqueId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let raw = sources[sourceId]?.items[opaqueId] else { return nil }
        guard let safe = try? FolderPaths.normalize(raw), FolderPaths.same(safe, raw) else {
            logger.log("folder \(sourceId): refusing unsafe stored path (\(LogRedact.id(opaqueId)))")
            return nil
        }
        return safe
    }

    /// 完整枚举成功后的对账：新路径分配 id；返回缺席的 opaqueId 集合（调用方按「源缺失」处理）。
    /// 枚举失败时不要调用（「不知道」≠ 源缺失）。
    func reconcile(sourceId: String, observedPaths: [String]) throws -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        guard var record = sources[sourceId] else { return [] }
        var seen: Set<String> = []
        // 持久化边界兜底：进映射的路径先过规范化（拒绝对路径与 ..；ADR §3）。
        let normalized = try observedPaths.map { try FolderPaths.normalize($0) }
        for path in normalized {
            if let (opaque, _) = record.items.first(where: { FolderPaths.same($0.value, path) }) {
                seen.insert(opaque)
                continue
            }
            let opaque = UUID().uuidString.lowercased()
            record.items[opaque] = path
            seen.insert(opaque)
        }
        let missing = Set(record.items.keys).subtracting(seen)
        sources[sourceId] = record
        persistLocked()
        return missing
    }
}



