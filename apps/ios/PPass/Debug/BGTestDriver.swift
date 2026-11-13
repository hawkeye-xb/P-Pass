#if DEBUG
import Foundation
import Photos
import PPassCore
import SQLite3
import UIKit
import UniformTypeIdentifiers

/// sqlite3_bind_text 的 destructor：让 sqlite 在语句执行期内复制字符串（Swift String 与 C 回调的边界）。
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 仅 DEBUG：tools/ios/sim-bg-task.sh（#958 后台短任务真机模拟）、tools/ios/e3-batch.sh、tools/ios/delete-test-assets.sh
/// 与 tools/e3/scenarios/ios/（#1744 目录来源真机 E3）用的驱动。
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
///
///   PPASS_BGTEST_FOLDER_ADD=<JSON>    #1744：把脚本推到 stage 的文件按 manifest 摆成嵌套目录 → 经真实
///                                     FolderRegistry.addFolder 登记（登记的启动是专用启动，见下）。JSON：
///                                     {"dir":"foldere3-<run>","stage":"foldere3-stage-<run>","display":"…",
///                                      "manifest":{"<目录内相对路径>":"<stage 里的文件名>",…}}；stage 缺省时目录必须已存在。
///   PPASS_BGTEST_FOLDER_LIST=1        导出登记记录（id / display / status / 项数）与每来源文件数，不改任何东西。
///   PPASS_BGTEST_FOLDER_RUN=1         空相册范围 + 自动备份开 + 触发一轮带对账的备份：folder: 项全部在范围内
///                                     （ADR §4），PhotoKit 一张都不进范围；轮询引擎事实直到收场并写进 status。
///   PPASS_BGTEST_FOLDER_MUTATE=<JSON> 对测试目录做增/改名/移/改/删（增的源文件在 stage），走真实 FileManager；
///                                     下一轮 reconcile 才发现——这正是 ADR E3「不依赖门铃」要验的语义。
///   PPASS_BGTEST_FOLDER_CORRUPT=<JSON> 对测试目录里一个文件做「改一字节 / 截断」（供数期反证注入，配合
///                                     PPASS_BGTEST_FOLDER_INTEGRITY 之外单独用：注入后由脚本拉证据判红）。
///   PPASS_BGTEST_FOLDER_INTEGRITY=<JSON> 一条启动里做完整反证闭环：等大文件导入完成 → 注入 → 等
///                                     「source changed while serving」→ 还原 → 再触发对账 → 等重新确认。
///   PPASS_BGTEST_FOLDER_DISK=1        实测各子树占盘字节（App tmp、provider blobs、账本、foldere3-* 测试目录）。
///   PPASS_BGTEST_FOLDER_CLEANUP=<JSON> 删 foldere3-* 测试目录（只认这个前缀）与 FolderE3 登记记录。
///   PPASS_BGTEST_FOLDER_PICK=1        弹系统目录选择器（由 UI 测试 FolderPickerDrive 点「打开」）；授权回调内经真实
///                                     addFolder 登记，PPASS_BGTEST_FOLDER_STAGE=1 时再把目录里最小的媒体文件
///                                     拷进 seed（相册+目录同内容去重用例）。
///
/// 目录钩子的注册表实例说明：FolderRegistry 约定一个进程一个实例；登记/改表类钩子各跑在专用启动里
/// （devicectl --terminate-existing 串行，产品实例在该启动里不写注册表，钩子写完即被下一个启动替换），
/// 不存在同一进程内两个写者。目录书签与相对路径只留在 App 私有容器（ADR §2：不写日志、不进协议）——
/// status.json 与 AppLog 只报步骤名、数量、状态与哈希前缀，不报路径。
@MainActor
enum BGTestDriver {
    static let albumPrefix = "PPass BGTest"
    /// #1744 测试目录与登记显示名共用的前缀（清理只认它，绝不碰用户素材）。
    static let folderPrefix = "foldere3-"
    static let folderDisplayPrefix = "PPass FolderE3"

    /// 处理了返回 true（E2EDriver 不再走默认的端到端流程）。
    static func run(model: AppModel, dir: URL, env: [String: String]) -> Bool {
        let run = env["PPASS_E2E_RUN"] ?? ""
        let link = env["PPASS_E2E_PAIR_LINK"] ?? ""
        let status = StatusFile(url: dir.appendingPathComponent("status.json"), run: run)
        // 驱动轮会让 App 长时间前台跑备份：别让自动锁屏把它压成后台（真机实测：锁屏后钩子冻结在半程）。
        // 只在 DEBUG 驱动轮设置，正常使用不受影响。
        UIApplication.shared.isIdleTimerDisabled = true
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
        } else if let spec = env["PPASS_BGTEST_FOLDER_ADD"] {
            Task { await folderAdd(spec: spec, run: run, status: status) }
        } else if env["PPASS_BGTEST_FOLDER_LIST"] == "1" {
            Task { await folderList(status: status) }
        } else if env["PPASS_BGTEST_FOLDER_RUN"] == "1" {
            Task { await folderRun(model: model, link: link, status: status) }
        } else if let spec = env["PPASS_BGTEST_FOLDER_MUTATE"] {
            Task { await folderMutate(spec: spec, status: status) }
        } else if let spec = env["PPASS_BGTEST_FOLDER_CORRUPT"] {
            Task { await folderCorrupt(spec: spec, status: status) }
        } else if let spec = env["PPASS_BGTEST_FOLDER_INTEGRITY"] {
            Task { await folderIntegrity(model: model, link: link, spec: spec, status: status) }
        } else if env["PPASS_BGTEST_FOLDER_DISK"] == "1" {
            folderDisk(status: status)
        } else if let spec = env["PPASS_BGTEST_FOLDER_CLEANUP"] {
            Task { await folderCleanup(spec: spec, status: status) }
        } else if env["PPASS_BGTEST_FOLDER_PICK"] == "1" {
            Task { await folderPick(model: model, run: run, stage: env["PPASS_BGTEST_FOLDER_STAGE"] == "1", status: status) }
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
        let since: BackupSince?
        do { since = try media.savedSince() } catch { status.write("failed", ["error": "scope since unreadable: \(error)", "done": true]); return }
        status.write("scope", ["selected": scopeJSON(saved),
                               "since_ms": { if case .since(let ms)? = since { return ms as Any } else { return NSNull() } }(),
                               "known": media.knownAlbums().sorted(),
                               "selected_test_albums": (saved ?? []).intersection(testAlbumIds).count,
                               "test_assets": testAssetIds().count, "done": true])
    }

    private static func pairOnly(model: AppModel, link: String, restore: String?, allowTestScope: Bool,
                                 status: StatusFile) async {
        let media = model.backend.media
        // 先清空：范围里可能还是测试相册，一连上正式桌面就会把测试照片备份进用户的真实库。
        let all = Set(((try? await media.albums()) ?? []).map(\.id))
        do { try await media.saveScope([], known: all, since: .all) } catch {
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
                    // 导出时没有 since_ms（全部，或 #1263 之前导出的）→ 全部。
                    let since = (json["since_ms"] as? NSNumber).map { BackupSince.since(ms: $0.int64Value) } ?? .all
                    try await media.saveScope(selected, known: known, since: since)
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
        model.albumsChosen([albumId], known: known, wantsAll: true, firstTime: firstTime) // 种进来的测试照片拍摄时间可能早于今天：时间档选「全部」
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

    // MARK: #1744 目录来源真机 E3 钩子

    private static func json(_ s: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
    }

    /// 测试目录名只认 foldere3- 前缀（清理绝不碰用户素材）；单段、无路径穿越。
    private static func safeName(_ s: String) -> Bool {
        !s.isEmpty && !s.contains("/") && !s.contains("..") && s.hasPrefix(folderPrefix)
    }

    private static func testRegistry() throws -> (FolderRegistry, URL) {
        let root = try LiveBackend.resolveRoot(logger: NoopLogger())
        return (FolderRegistry(directory: root.url, logger: NoopLogger()), root.url)
    }

    /// 已配对就不再配（folder-run 常接在 seedRun 之后，同一沙盒不重配）。
    private static func ensurePaired(model: AppModel, link: String, dir: URL) async -> Bool {
        if model.backend.pairing.pairedAtMs() != nil { return true }
        let outcome = await E2EPairCode.pair(model.backend.pairing, link: link, dir: dir)
        guard case .joined(let firstTime, let settingSaveFailed) = outcome else { return false }
        model.paired(firstTime: firstTime, settingSaveFailed: settingSaveFailed)
        return true
    }

    /// 空相册范围 + 自动备份开 + 触发一轮带对账的备份：folder: 项全部在范围内（ADR §4），PhotoKit 一张都不进。
    /// 相册权限：**不主动 requestAccess**（后台启动弹窗无人点会永久卡住；真机实测）。目录来源不依赖 PhotoKit，
    /// 权限不是 .full 只影响 PhotoKit 侧（mediaAbsenceTrusted=false、相册侧无发现），folder: 项的发现/导入/传输照常。
    /// 需要相册的场景（dedupe 的 seedRun）自带 requestAccess 路径。
    private static func folderBegin(model: AppModel, link: String, status: StatusFile) async -> Bool {
        let access = model.backend.media.access()
        status.write("access", ["level": "\(access)"])
        let alreadyPaired = model.backend.pairing.pairedAtMs() != nil
        if !alreadyPaired {
            guard await ensurePaired(model: model, link: link, dir: status.url.deletingLastPathComponent()) else {
                status.write("failed", ["error": "pairing failed", "done": true]); return false
            }
            status.write("paired")
        } else {
            status.write("paired", ["already": true])
        }
        let albums = (try? await model.backend.media.albums()) ?? []
        let known = Set(albums.map(\.id))
        // 已保存的非空相册范围（如 dedupe 用例里 seedRun 选的测试相册）保持不动；空/未保存才写空范围。
        // 不走 model.albumsChosen：它的 firstTime 路径（finishFirstScope）是异步 Task，会把自动备份写回「关」，
        // 与下面 setAutoBackup(true) 竞态（真机实测 04:30:01 on=true→on=false）。这里直接写引擎层三件事：
        let saved = (try? model.backend.media.savedScope()) ?? nil
        if (saved ?? []).isEmpty {
            do { try await model.backend.media.saveScope([], known: known, since: .all) } catch {
                status.write("failed", ["error": "save empty scope: \(error)", "done": true]); return false
            }
        }
        do { try model.backend.engine.setAutoRule(true) } catch {
            status.write("failed", ["error": "setAutoRule: \(error)", "done": true]); return false
        }
        model.setAutoBackup(true) // 目录来源是持续自动备份（ADR §1）；前台轮不需要它，按真实使用状态设上
        await model.backend.engine.wake() // trigger(.scopeAdded)：带 reconcile 的轮，folder: 项这一轮被发现
        return true
    }

    /// folder: 订单状态全集（只读账本；路径不外带）。
    private static func folderOrderStates(rootURL: URL) -> [String] {
        var db: OpaquePointer?
        let path = rootURL.appendingPathComponent("backup-orders.db")
        guard sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, db != nil else {
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT state FROM orders WHERE media_id LIKE 'folder:%' ORDER BY id", -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) {
            out.append(String(cString: c))
        }
        return out
    }

    /// 轮询直到收场：账本里 folder: 订单全部 CONFIRMED 且引擎停转（连稳两拍）；超时返回 false。
    /// 不能用 FlowFacts.inScopeTotal 判完成：它只算所选相册的 PhotoKit 项（LiveMediaLibrary.inScopeTotal），
    /// 目录-only 轮恒为 0——目录项的完成事实只能看账本。
    private static func waitFolderDone(model: AppModel, rootURL: URL, timeoutSecs: Double, status: StatusFile) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSecs)
        var stable = 0
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let f = model.backend.engine.facts()
            let states = folderOrderStates(rootURL: rootURL)
            let unsettled = states.filter { $0 != "CONFIRMED" }
            status.write("backing_up", ["folder_orders": states.count, "non_confirmed": unsettled.count,
                                        "state": "\(f.state)", "wait_reason": "\(String(describing: f.waitReason))"])
            let engineQuiet = f.state != .running
            if !states.isEmpty, unsettled.isEmpty, engineQuiet {
                stable += 1
                if stable >= 2 { return true }
            } else {
                stable = 0
            }
            // 一张订单都没建、引擎也停了：目录项没被发现（登记丢失 / 枚举为空），别等满超时
            if states.isEmpty, engineQuiet, stable == 0, f.confirmed == 0, f.unfinished == 0 {
                // 给对账两拍机会再判死
                stable -= 1
                if stable <= -3 { return false }
            }
        }
        return false
    }

    private static func folderRun(model: AppModel, link: String, status: StatusFile) async {
        status.write("started")
        guard await folderBegin(model: model, link: link, status: status) else { return }
        let rootURL = (try? LiveBackend.resolveRoot(logger: NoopLogger()).url) ?? URL(fileURLWithPath: "/nonexistent")
        guard await waitFolderDone(model: model, rootURL: rootURL, timeoutSecs: 900, status: status) else {
            status.write("failed", ["error": "folder backup did not finish before timeout", "done": true]); return
        }
        let states = folderOrderStates(rootURL: rootURL)
        status.write("done", ["done": true, "ok": true, "folder_orders": states.count,
                              "confirmed": states.filter { $0 == "CONFIRMED" }.count])
    }

    /// stage → 测试目录（按 manifest 摆嵌套）→ 真实 addFolder 登记。
    private static func folderAdd(spec: String, run: String, status: StatusFile) async {
        status.write("started")
        guard let spec0 = json(spec), let dirName = spec0["dir"] as? String, safeName(dirName) else {
            status.write("failed", ["error": "bad spec", "done": true]); return
        }
        let docs = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        let base = docs.appendingPathComponent(dirName)
        let fm = FileManager.default
        if let stageName = spec0["stage"] as? String, safeName(stageName), let manifest = spec0["manifest"] as? [String: String] {
            let stage = docs.appendingPathComponent(stageName)
            for (target, sourceName) in manifest.sorted(by: { $0.key < $1.key }) {
                guard let rel = try? FolderPaths.normalize(target) else {
                    status.write("failed", ["error": "bad manifest target", "done": true]); return
                }
                let dest = base.appendingPathComponent(rel)
                do {
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: stage.appendingPathComponent(sourceName), to: dest)
                } catch {
                    status.write("failed", ["error": "stage move failed: \(error.localizedDescription)", "done": true]); return
                }
            }
            // stage 目录保留：manifest 之外的文件（如 reconcile 用例后续「增」要用的素材）还在里面，
            // 由 CLEANUP 钩子按 foldere3- 前缀统一清。
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: base.path, isDirectory: &isDir), isDir.boolValue else {
            status.write("failed", ["error": "test folder missing", "done": true]); return
        }
        do {
            let (registry, _) = try testRegistry()
            let display = (spec0["display"] as? String) ?? "\(folderDisplayPrefix) \(run)"
            let sourceId = try registry.addFolder(at: base, displayName: display)
            status.write("folder_added", ["source_id": sourceId, "display": display,
                                          "items": registry.record(id: sourceId)?.items.count ?? 0, "done": true])
        } catch {
            status.write("failed", ["error": "addFolder: \(error.localizedDescription)", "done": true])
        }
    }

    private static func folderList(status: StatusFile) async {
        guard let (registry, _) = try? testRegistry() else {
            status.write("failed", ["error": "resolve root failed", "done": true]); return
        }
        var sources: [[String: Any]] = []
        for r in registry.allRecords() {
            var entry: [String: Any] = ["id": r.id, "display": r.displayName, "status": r.status, "items": r.items.count]
            // 源目录媒体总字节（护栏用：真机备份前先知道要往沙盒桌面写多少）；路径不外带。
            if let root = try? FolderBookmarks.resolve(r, registry: registry, logger: NoopLogger()) {
                var total: Int64 = 0
                try? await FolderBookmarks.withScope(root.url) { _ in
                    func walk(_ url: URL) {
                        guard let files = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isDirectoryKey]) else { return }
                        for f in files {
                            let values = try? f.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
                            if values?.isDirectory == true { walk(f) }
                            else if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
                        }
                    }
                    walk(root.url)
                }
                entry["total_bytes"] = total
            }
            sources.append(entry)
        }
        status.write("folder_list", ["sources": sources, "done": true])
    }

    /// 测试目录内增 / 改名 / 移 / 改 / 删；路径不进日志与 status（只报 op 与结果）。
    private static func folderMutate(spec: String, status: StatusFile) async {
        status.write("started")
        guard let spec0 = json(spec), let dirName = spec0["dir"] as? String, safeName(dirName),
              let ops = spec0["ops"] as? [[String: Any]] else {
            status.write("failed", ["error": "bad spec", "done": true]); return
        }
        let docs = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        let base = docs.appendingPathComponent(dirName)
        let fm = FileManager.default
        func rel(_ op: [String: Any], _ key: String) -> URL? {
            guard let raw = op[key] as? String, let norm = try? FolderPaths.normalize(raw) else { return nil }
            return base.appendingPathComponent(norm)
        }
        var results: [[String: Any]] = []
        for (i, op) in ops.enumerated() {
            let kind = op["op"] as? String ?? ""
            var entry: [String: Any] = ["index": i, "op": kind]
            var ok = false
            switch kind {
            case "add": // from = stage 文件名；to = 目录内相对路径
                if let stageName = spec0["stage"] as? String, safeName(stageName), let from = op["from"] as? String, let to = rel(op, "to") {
                    do {
                        try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fm.moveItem(at: docs.appendingPathComponent(stageName).appendingPathComponent(from), to: to)
                        entry["size"] = ((try? fm.attributesOfItem(atPath: to.path))?[.size] as? NSNumber)?.intValue ?? -1
                        ok = true
                    } catch {}
                }
            case "rename", "move":
                if let from = rel(op, "from"), let to = rel(op, "to") {
                    do {
                        try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fm.moveItem(at: from, to: to)
                        ok = true
                    } catch {}
                }
            case "delete":
                if let path = rel(op, "to") ?? rel(op, "from"), ((try? fm.removeItem(at: path)) != nil) { ok = true }
            case "modify": // 改一字节：offset 处比特翻转，由对账发现
                if let path = rel(op, "to") ?? rel(op, "from"), let offset = op["offset"] as? Int,
                   let handle = try? FileHandle(forReadingFrom: path) {
                    defer { try? handle.close() }
                    do {
                        try handle.seek(toOffset: UInt64(offset))
                        let byte = try handle.read(upToCount: 1)?.first
                        if let byte {
                            try handle.seek(toOffset: UInt64(offset))
                            try handle.write(Data([byte ^ 0xFF]))
                            entry["old_byte"] = byte
                            entry["new_byte"] = byte ^ 0xFF
                            ok = true
                        }
                    } catch {}
                }
            default: break
            }
            entry["ok"] = ok
            results.append(entry)
        }
        let okCount = results.filter { ($0["ok"] as? Bool) == true }.count
        AppLog.log("foldere3: mutate ok=\(okCount)/\(results.count)")
        status.write("mutated", ["results": results, "done": true])
    }

    /// 对测试目录里一个文件注入故障（flip = 改一字节 / truncate = 截断）。返回事实条目；truncate 会带回原内容。
    private static func corruptFile(record: FolderRecord, registry: FolderRegistry, relativePath: String,
                                    mode: String, spec: [String: Any], status: StatusFile) async -> ([String: Any], Data?)? {
        guard mode == "flip" || mode == "truncate",
              let root = try? FolderBookmarks.resolve(record, registry: registry, logger: NoopLogger()) else {
            status.write("failed", ["error": "bad corrupt spec", "done": true]); return nil
        }
        let target = root.url.appendingPathComponent(relativePath)
        do {
            var entry: [String: Any] = ["mode": mode]
            var backup: Data?
            try await FolderBookmarks.withScope(root.url) { _ in
                let attr = try FileManager.default.attributesOfItem(atPath: target.path)
                let size = (attr[.size] as? NSNumber)?.int64Value ?? 0
                guard size > 0 else { throw FolderSourceError(reason: "empty file") }
                entry["size_before"] = size
                let handle = try FileHandle(forReadingFrom: target)
                defer { try? handle.close() }
                if mode == "flip" {
                    let offset = (spec["offset"] as? Int) ?? Int(size - 1)
                    try handle.seek(toOffset: UInt64(offset))
                    let byte = try handle.read(upToCount: 1)?.first
                    guard let byte else { throw FolderSourceError(reason: "read byte failed") }
                    try handle.seek(toOffset: UInt64(offset))
                    try handle.write(Data([byte ^ 0xFF]))
                    entry["offset"] = offset
                    entry["old_byte"] = byte
                    entry["new_byte"] = byte ^ 0xFF
                } else {
                    let keep = (spec["offset"] as? Int) ?? Int(size / 2)
                    backup = try Data(contentsOf: target) // 还原用；大文件仅在此反证启动的内存里
                    try handle.truncate(atOffset: UInt64(keep))
                    entry["offset"] = keep
                    entry["size_after"] = keep
                }
            }
            AppLog.log("foldere3: corrupt mode=\(mode) ok=1")
            return (entry, backup)
        } catch {
            status.write("failed", ["error": "corrupt: \(error.localizedDescription)", "done": true]); return nil
        }
    }

    private static func restoreFile(record: FolderRecord, registry: FolderRegistry, relativePath: String,
                                    corrupt: [String: Any], backup: Data?) async -> Bool {
        guard let root = try? FolderBookmarks.resolve(record, registry: registry, logger: NoopLogger()) else { return false }
        let target = root.url.appendingPathComponent(relativePath)
        do {
            try await FolderBookmarks.withScope(root.url) { _ in
                if corrupt["mode"] as? String == "flip" {
                    let offset = (corrupt["offset"] as? Int) ?? 0
                    let byte = (corrupt["old_byte"] as? UInt8) ?? 0
                    let handle = try FileHandle(forWritingTo: target)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: UInt64(offset))
                    try handle.write(Data([byte]))
                } else if let backup {
                    try backup.write(to: target, options: .atomic)
                }
            }
            AppLog.log("foldere3: restore ok=1")
            return true
        } catch {
            AppLog.log("foldere3: restore failed (\(error.localizedDescription))")
            return false
        }
    }

    /// 只跑反证注入：注入后由脚本拉证据判红（不还原、不等收场）。
    private static func folderCorrupt(spec: String, status: StatusFile) async {
        status.write("started")
        guard let spec0 = json(spec), let dirName = spec0["dir"] as? String, safeName(dirName),
              let fileName = spec0["file"] as? String, let rel = try? FolderPaths.normalize(fileName),
              let (registry, _) = try? testRegistry(),
              let record = registry.allRecords().first(where: { $0.displayName.hasPrefix(folderDisplayPrefix) }) else {
            status.write("failed", ["error": "bad spec or no registered folder source", "done": true]); return
        }
        guard let _ = await corruptFile(record: record, registry: registry, relativePath: rel,
                                        mode: spec0["mode"] as? String ?? "flip", spec: spec0, status: status) else { return }
        status.write("done", ["done": true])
    }

    private static func orderStates(at dbPath: URL, mediaId: String) -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, db != nil else {
            if let db { sqlite3_close(db) }
            return ["<db-unavailable>"]
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT state FROM orders WHERE media_id = ? ORDER BY id", -1, &stmt, nil) == SQLITE_OK else {
            return ["<query-failed>"]
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, mediaId, -1, SQLITE_TRANSIENT)
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) {
            out.append(String(cString: c))
        }
        return out
    }

    /// 完整反证闭环（一次启动内）：等导入 → 注入 → 等「source changed while serving」→ 查订单未确认 → 还原 → 再触发 → 等重新确认。
    /// spec 的 "display"（可选）指定目标登记记录：反证必须在**尚未备份过**的来源上做——已确认项不会重新导入，
    /// 等不到新的导入-供数窗口。
    private static func folderIntegrity(model: AppModel, link: String, spec: String, status: StatusFile) async {
        status.write("started")
        guard let spec0 = json(spec), let dirName = spec0["dir"] as? String, safeName(dirName),
              let fileName = spec0["file"] as? String, let rel = try? FolderPaths.normalize(fileName),
              let (registry, rootURL) = try? testRegistry(),
              let wanted = spec0["display"] as? String,
              let record = registry.allRecords().first(where: { $0.displayName == wanted })
                  ?? registry.allRecords().first(where: { $0.displayName.hasPrefix(folderDisplayPrefix) }) else {
            status.write("failed", ["error": "bad spec or no registered folder source", "done": true]); return
        }
        let mode = spec0["mode"] as? String ?? "flip"
        let sourceId = record.id
        var size: Int64 = -1
        do {
            let root = try FolderBookmarks.resolve(record, registry: registry, logger: NoopLogger())
            try await FolderBookmarks.withScope(root.url) { _ in
                let attr = try FileManager.default.attributesOfItem(atPath: root.url.appendingPathComponent(rel).path)
                size = (attr[.size] as? NSNumber)?.int64Value ?? -1
            }
        } catch {
            status.write("failed", ["error": "stat: \(error.localizedDescription)", "done": true]); return
        }
        guard size > 0 else { status.write("failed", ["error": "empty file", "done": true]); return }
        let opaque = registry.opaqueId(sourceId: sourceId, relativePath: rel)
        let mediaId = "folder:\(sourceId):\(opaque)"
        let logPath = NSHomeDirectory() + "/Library/Logs/ppass.log"
        status.write("armed", ["size": size, "mode": mode])
        // 1. 触发一轮带对账的备份（配对、空相册范围、自动备份开）
        let baseline = logOffset(logPath)
        guard await folderBegin(model: model, link: link, status: status) else { return }
        // 2. 等这个文件的引用导入完成（sourceId 唯一，旧行不会撞上）
        guard let importedLine = await waitLog(pattern: "folder \(sourceId): imported bytes=\(size) hash=.* ref=yes",
                                               fromOffset: baseline, timeoutSecs: 300, logPath: logPath) else {
            status.write("failed", ["error": "reference import not observed", "done": true]); return
        }
        status.write("imported", ["line": String(importedLine.suffix(80))])
        // 3. 注入故障
        guard let (corrupt, backup) = await corruptFile(record: record, registry: registry, relativePath: rel,
                                                        mode: mode, spec: spec0, status: status) else { return }
        status.write("corrupted", corrupt)
        // 4. 供数期源被改：传输必须放弃（不得确认）
        if await waitLog(pattern: "source changed while serving", fromOffset: logOffset(logPath),
                         timeoutSecs: 240, logPath: logPath) == nil {
            status.write("failed", ["error": "serve did not abort after corruption", "done": true]); return
        }
        status.write("serve_aborted")
        // 5. 注入那一刻该张的订单历史（不得出现 CONFIRMED 的坏内容版本）
        let statesAfterAbort = orderStates(at: rootURL.appendingPathComponent("backup-orders.db"), mediaId: mediaId)
        status.write("orders_after_abort", ["states": statesAfterAbort])
        if statesAfterAbort.contains("CONFIRMED") {
            status.write("failed", ["error": "corrupted content got CONFIRMED", "done": true]); return
        }
        // 6. 还原 → 再触发对账 → 等重新确认（内容与导入一致）
        guard await restoreFile(record: record, registry: registry, relativePath: rel, corrupt: corrupt, backup: backup) else {
            status.write("failed", ["error": "restore failed", "done": true]); return
        }
        status.write("restored")
        await model.backend.engine.wake()
        let deadline = Date().addingTimeInterval(600)
        var confirmed = false
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let states = orderStates(at: rootURL.appendingPathComponent("backup-orders.db"), mediaId: mediaId)
            status.write("waiting_reconfirm", ["latest": states.last ?? "?", "history": states])
            if states.last == "CONFIRMED" { confirmed = true; break }
        }
        guard confirmed else { status.write("failed", ["error": "re-import did not confirm", "done": true]); return }
        status.write("done", ["done": true, "ok": true])
    }

    private static func logOffset(_ path: String) -> UInt64 {
        let attr = try? FileManager.default.attributesOfItem(atPath: path)
        return (attr?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// 从 fromOffset 起增量尾读 App 日志，找到第一条匹配行；超时返回 nil。
    private static func waitLog(pattern: String, fromOffset: UInt64, timeoutSecs: Double, logPath: String) async -> String? {
        let deadline = Date().addingTimeInterval(timeoutSecs)
        var offset = fromOffset
        var consumed = Data()
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: logPath)) else { continue }
            defer { try? handle.close() }
            guard (try? handle.seek(toOffset: offset)) != nil else { continue }
            guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else { continue }
            offset += UInt64(chunk.count)
            consumed.append(chunk)
            if consumed.count > 8 << 20 { consumed = consumed.suffix(1 << 20) }
            guard let text = String(data: consumed, encoding: .utf8),
                  let range = text.range(of: pattern, options: .regularExpression) else { continue }
            return String(text[range])
        }
        return nil
    }

    /// 实测各子树占盘字节（ADR E3：不能只检查 App tmp）。
    private static func folderDisk(status: StatusFile) {
        func du(_ url: URL) -> Int64 {
            var total: Int64 = 0
            let fm = FileManager.default
            if let attr = try? fm.attributesOfItem(atPath: url.path), let size = (attr[.size] as? NSNumber)?.int64Value {
                total += size
            }
            if let children = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                for child in children { total += du(child) }
            }
            return total
        }
        var bytes: [String: Int64] = ["app_tmp": du(FileManager.default.temporaryDirectory)]
        if let root = try? LiveBackend.resolveRoot(logger: NoopLogger()).url {
            bytes["storage_root"] = du(root)
            bytes["provider_blobs"] = du(root.appendingPathComponent("blobs"))
            bytes["orders_db"] = du(root.appendingPathComponent("backup-orders.db"))
        }
        let docs = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        if let children = try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil) {
            for child in children where child.lastPathComponent.hasPrefix(folderPrefix) {
                bytes["test_dir_\(child.lastPathComponent)"] = du(child)
            }
        }
        AppLog.log("foldere3: disk measured entries=\(bytes.count)")
        status.write("disk", ["bytes": bytes, "done": true])
    }

    /// 清理：删 foldere3-* 测试目录（只认前缀）与 FolderE3 登记记录；绝不碰用户素材。
    private static func folderCleanup(spec: String, status: StatusFile) async {
        let docs = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        var removedDirs = 0
        var removedRecords = 0
        if let spec0 = json(spec) {
            for dirName in (spec0["dirs"] as? [String] ?? []) where safeName(dirName) {
                if ((try? FileManager.default.removeItem(at: docs.appendingPathComponent(dirName))) != nil) { removedDirs += 1 }
            }
        }
        if let (registry, _) = try? testRegistry() {
            for record in registry.allRecords() where record.displayName.hasPrefix(folderDisplayPrefix) {
                registry.removeFolder(id: record.id)
                removedRecords += 1
            }
        }
        status.write("cleaned", ["removed_dirs": removedDirs, "removed_records": removedRecords, "done": true])
    }

    /// 弹系统目录选择器；授权回调内经真实 addFolder 登记（回调返回后作用域即失效，一切必须在回调内完成）。
    private static var pickBox: FolderPickBox?
    private static func folderPick(model: AppModel, run: String, stage: Bool, status: StatusFile) async {
        var host: UIViewController?
        for _ in 0..<50 {
            if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
               let window = scene.windows.first(where: { $0.isKeyWindow }) {
                var top = window.rootViewController
                while let presented = top?.presentedViewController { top = presented }
                if top != nil { host = top; break }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        guard let host else {
            status.write("failed", ["error": "no foreground scene to present picker", "done": true]); return
        }
        let box = FolderPickBox(run: run, stage: stage, status: status)
        pickBox = box
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = box
        host.present(picker, animated: true)
        status.write("picker_presented")
    }
}

/// 目录选择器的授权回调：登记与取样都在回调内同步完成（作用域随回调返回失效）。
private final class FolderPickBox: NSObject, UIDocumentPickerDelegate {
    private let run: String
    private let stage: Bool
    private let status: StatusFile

    init(run: String, stage: Bool, status: StatusFile) {
        self.run = run
        self.stage = stage
        self.status = status
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { status.write("failed", ["error": "no url picked", "done": true]); return }
        do {
            let root = try LiveBackend.resolveRoot(logger: NoopLogger())
            let registry = FolderRegistry(directory: root.url, logger: NoopLogger())
            let display = "\(BGTestDriver.folderDisplayPrefix) BM \(run)"
            let sourceId = try registry.addFolder(at: url, displayName: display)
            var staged: [String: Any] = [:]
            if stage {
                // 目录里最小的媒体文件拷进 seed（相册+目录同内容去重用例）；在回调作用域内读取。
                let mediaExts = ["jpg", "jpeg", "png", "heic", "mov", "mp4", "m4v"]
                let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]))?
                    .filter { mediaExts.contains($0.pathExtension.lowercased()) }
                    .compactMap { child -> (URL, Int)? in
                        let size = (try? child.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
                        return size >= 0 ? (child, size) : nil
                    }
                if let smallest = files?.min(by: { $0.1 < $1.1 }) {
                    let seedDir = status.url.deletingLastPathComponent().appendingPathComponent("seed", isDirectory: true)
                    try FileManager.default.createDirectory(at: seedDir, withIntermediateDirectories: true)
                    let dest = seedDir.appendingPathComponent("foldere3-dedup.\(smallest.0.pathExtension.lowercased())")
                    try FileManager.default.copyItem(at: smallest.0, to: dest)
                    staged = ["name": dest.lastPathComponent, "size": smallest.1]
                }
            }
            status.write("folder_picked", ["source_id": sourceId, "display": display, "staged": staged, "done": true])
            AppLog.log("foldere3: picked folder registered")
        } catch {
            status.write("failed", ["error": "pick register: \(error.localizedDescription)", "done": true])
        }
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
