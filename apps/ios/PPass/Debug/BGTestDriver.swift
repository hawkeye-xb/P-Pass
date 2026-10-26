#if DEBUG
import Foundation
import Photos
import PPassCore

/// 仅 DEBUG：tools/ios/sim-bg-task.sh（#958 后台短任务真机模拟）、tools/ios/e3-batch.sh 与 tools/ios/delete-test-assets.sh 用的驱动。
/// 经 E2EDriver 进来（PPASS_E2E_DIR=container），状态写 `<dir>/status.json`，脚本用 devicectl 拉回。一次启动只做一种：
///
///   PPASS_BGTEST_SCOPE_EXPORT=1  导出当前相册范围（selected / known）和测试相册里的资源数，不改任何东西。
///   PPASS_BGTEST=1               清存储根（PPASS_E2E_RESET）后：配对临时 daemon → 新建空相册「PPass BGTest <run>」并只选它 → `ready`；
///                                等脚本把 *.jpg / *.mov 和信号文件 `go` 拷进 `<dir>/seed/`，写进这个相册 → `seeded`。
///                                每轮一个新相册：旧相册里的照片不会混进这一轮的待传。
///   PPASS_BGTEST_DUMP=1          把存储根里的账本（backup-orders.db / -wal / -shm）拷到 `<dir>/db`（脚本统一从这里拉）。
///   PPASS_BGTEST_PAIR_ONLY=1     配回正式桌面：先把范围清空 → 配对（PPASS_E2E_PAIR_LINK）→ 若给了
///                                PPASS_BGTEST_SCOPE_RESTORE（导出时的 JSON {selected, known}），且所选相册里**没有任何测试资源**，
///                                恢复成那组范围；有交集就保持空范围并报 `scope_conflict`（不让测试照片进用户真实的照片库）。
///                                PPASS_BGTEST_ALLOW_TEST_SCOPE=1：对端是测试沙盒 daemon（e3-batch.sh），没有真实照片库要护，
///                                测试相册照样恢复。
///   PPASS_BGTEST_DELETE_TEST=1   删除所有「PPass BGTest *」相册里的资源和这些相册。iOS 会弹系统确认框，要人在手机上点「删除」。
@MainActor
enum BGTestDriver {
    static let albumPrefix = "PPass BGTest"

    /// 处理了返回 true（E2EDriver 不再走默认的端到端流程）。
    static func run(model: AppModel, dir: URL, env: [String: String]) -> Bool {
        let run = env["PPASS_E2E_RUN"] ?? ""
        let link = env["PPASS_E2E_PAIR_LINK"] ?? ""
        let status = StatusFile(url: dir.appendingPathComponent("status.json"), run: run)
        if env["PPASS_BGTEST_SCOPE_EXPORT"] == "1" {
            Task { await exportScope(model: model, status: status) }
        } else if env["PPASS_BGTEST"] == "1" {
            Task { await seedRun(model: model, dir: dir, link: link, run: run, status: status) }
        } else if env["PPASS_BGTEST_DUMP"] == "1" {
            dumpLedger(dir: dir, status: status)
        } else if env["PPASS_BGTEST_PAIR_ONLY"] == "1" {
            Task {
                await pairOnly(model: model, link: link, restore: env["PPASS_BGTEST_SCOPE_RESTORE"],
                               allowTestScope: env["PPASS_BGTEST_ALLOW_TEST_SCOPE"] == "1", status: status)
            }
        } else if env["PPASS_BGTEST_DELETE_TEST"] == "1" {
            Task { await deleteTestAssets(status: status) }
        } else {
            return false
        }
        return true
    }

    // MARK: 范围导出 / 恢复

    private static func exportScope(model: AppModel, status: StatusFile) async {
        let media = model.backend.media
        let testAlbumIds = Set(testAlbums().map(\.localIdentifier))
        let saved: Set<String>?
        do { saved = try media.savedScope() } catch { status.write("failed", ["error": "scope unreadable: \(error)", "done": true]); return }
        status.write("scope", ["selected": scopeJSON(saved),
                               "known": media.knownAlbums().sorted(),
                               "selected_test_albums": (saved ?? []).intersection(testAlbumIds).count,
                               "test_assets": testAssetIds().count, "done": true])
    }

    private static func pairOnly(model: AppModel, link: String, restore: String?, allowTestScope: Bool,
                                 status: StatusFile) async {
        let media = model.backend.media
        // 先清空：范围里可能还是测试相册，一连上正式桌面就会把测试照片备份进用户的真实库。
        let all = Set(((try? await media.albums()) ?? []).map(\.id))
        do { try await media.saveScope([], known: all) } catch {
            status.write("failed", ["error": "clear scope: \(error)", "done": true]); return
        }
        let outcome = await E2EPairCode.pair(model.backend.pairing, link: link, dir: status.url.deletingLastPathComponent())
        guard case .joined(let firstTime, let settingSaveFailed) = outcome else {
            status.write("failed", ["error": "pairing: \(outcome)", "done": true]); return
        }
        model.paired(firstTime: firstTime, settingSaveFailed: settingSaveFailed)
        var extra: [String: Any] = ["pair_outcome": "\(outcome)", "done": true]
        if let restore, let data = restore.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            guard let selectedList = json["selected"] as? [String] else {
                // 导出时从未保存过范围（nil）：saveScope 只能写集合，回不到 nil，保持空范围，交给人处理。
                extra["scope_restored"] = false
                extra["scope_error"] = "exported scope was never saved (null); left empty"
                status.write("paired", extra); return
            }
            let selected = Set(selectedList)
            let known = Set(json["known"] as? [String] ?? [])
            let test = testAssetIds()
            var inSelected = Set<String>()
            for id in selected { inSelected.formUnion(PhotoKitAlbums.assetIds(inCollection: id)) }
            let conflict = allowTestScope ? [] : inSelected.intersection(test)
            if conflict.isEmpty {
                do {
                    try await media.saveScope(selected, known: known)
                    extra["scope_restored"] = true
                } catch {
                    extra["scope_restored"] = false
                    extra["scope_error"] = "save scope: \(error)"
                }
            } else {
                extra["scope_restored"] = false
                extra["scope_conflict"] = conflict.count
            }
            do { extra["selected"] = scopeJSON(try media.savedScope()) } catch { extra["selected_error"] = "\(error)" }
            extra["known"] = media.knownAlbums().sorted()
        }
        status.write("paired", extra)
    }

    /// nil（从未保存过范围）写成 JSON null，与空数组（一个都不备份）区分开。
    private static func scopeJSON(_ scope: Set<String>?) -> Any {
        guard let scope else { return NSNull() }
        return scope.sorted()
    }

    // MARK: 测试相册

    /// 所有「PPass BGTest *」相册里的资源（照片 + 视频）。
    static func testAssetIds() -> Set<String> {
        var out = Set<String>()
        for album in testAlbums() { out.formUnion(PhotoKitAlbums.assetIds(inCollection: album.localIdentifier)) }
        return out
    }

    private static func testAlbums() -> [PHAssetCollection] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title BEGINSWITH %@", albumPrefix)
        let result = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options)
        var out: [PHAssetCollection] = []
        result.enumerateObjects { c, _, _ in out.append(c) }
        return out
    }

    private static func deleteTestAssets(status: StatusFile) async {
        let ids = Array(testAssetIds())
        let albums = testAlbums()
        status.write("deleting", ["assets": ids.count, "albums": albums.count])
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil))
                PHAssetCollectionChangeRequest.deleteAssetCollections(albums as NSArray)
            }
            status.write("deleted", ["remaining": testAssetIds().count, "done": true])
        } catch {
            status.write("failed", ["error": "delete: \(error)", "done": true])
        }
    }

    // MARK: 一轮模拟的准备

    private static func seedRun(model: AppModel, dir: URL, link: String, run: String, status: StatusFile) async {
        let backend = model.backend
        status.write("started")
        let access = await backend.media.requestAccess()
        guard access == .full else { status.write("failed", ["error": "photo access is \(access), need full", "done": true]); return }
        let outcome = await E2EPairCode.pair(backend.pairing, link: link, dir: dir)
        guard case .joined(let firstTime, let settingSaveFailed) = outcome else { status.write("failed", ["error": "pairing: \(outcome)", "done": true]); return }
        model.paired(firstTime: firstTime, settingSaveFailed: settingSaveFailed)
        status.write("paired")

        var albumId: String?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                albumId = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: "\(albumPrefix) \(run)")
                    .placeholderForCreatedAssetCollection.localIdentifier
            }
        } catch { status.write("failed", ["error": "create album: \(error)", "done": true]); return }
        guard let albumId else { status.write("failed", ["error": "create album: no id", "done": true]); return }
        let known = Set(((try? await backend.media.albums()) ?? []).map(\.id)).union([albumId])
        model.albumsChosen([albumId], known: known, firstTime: firstTime)
        status.write("ready")

        let seed = dir.appendingPathComponent("seed", isDirectory: true)
        try? FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        while !FileManager.default.fileExists(atPath: seed.appendingPathComponent("go").path) {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        let files = ((try? FileManager.default.contentsOfDirectory(at: seed, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let photos = files.filter { $0.pathExtension.lowercased() == "jpg" }
        let videos = files.filter { $0.pathExtension.lowercased() == "mov" }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumId], options: nil).firstObject,
                      let change = PHAssetCollectionChangeRequest(for: album) else { return }
                var placeholders: [PHObjectPlaceholder] = []
                for url in photos {
                    if let p = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)?.placeholderForCreatedAsset { placeholders.append(p) }
                }
                for url in videos {
                    if let p = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)?.placeholderForCreatedAsset { placeholders.append(p) }
                }
                change.addAssets(placeholders as NSArray)
            }
        } catch { status.write("failed", ["error": "seed: \(error)", "done": true]); return }
        try? FileManager.default.removeItem(at: seed)
        status.write("seeded", ["photos": photos.count, "videos": videos.count, "done": true, "ok": true])
    }

    // MARK: 账本导出

    private static func dumpLedger(dir: URL, status: StatusFile) {
        let target = dir.appendingPathComponent("db", isDirectory: true)
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        var copied: [String] = []
        if let root = try? LiveBackend.resolveRoot(logger: NoopLogger()).url {
            for name in ["backup-orders.db", "backup-orders.db-wal", "backup-orders.db-shm"] {
                let src = root.appendingPathComponent(name)
                if (try? FileManager.default.copyItem(at: src, to: target.appendingPathComponent(name))) != nil { copied.append(name) }
            }
        }
        status.write("dumped", ["copied": copied, "done": true])
    }
}

private enum PhotoKitAlbums {
    static func assetIds(inCollection id: String) -> Set<String> {
        guard let c = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject else { return [] }
        var out = Set<String>()
        PHAsset.fetchAssets(in: c, options: nil).enumerateObjects { a, _, _ in out.insert(a.localIdentifier) }
        return out
    }
}

/// `status.json`：每一步原子重写，字段累加。
@MainActor
private final class StatusFile {
    let url: URL
    private var fields: [String: Any]

    init(url: URL, run: String) {
        self.url = url
        fields = ["run": run]
    }

    func write(_ step: String, _ extra: [String: Any] = [:]) {
        fields["step"] = step
        for (k, v) in extra { fields[k] = v }
        if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .prettyPrinted]) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
#endif
