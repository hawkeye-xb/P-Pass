#if DEBUG
import Foundation
import Photos
import PPassCore
import PPassMedia
import PPassTransport
import UIKit

/// 仅 DEBUG：模拟器端到端（tools/ios/e2e-sim.sh）的驱动。
///
/// 用环境变量启用（`SIMCTL_CHILD_` 前缀经 `simctl launch` 传入）：
///   PPASS_E2E_DIR        状态文件目录（`status.json` 每一步原子重写；`done` = 跑完）
///   PPASS_E2E_PAIR_LINK  配对串（ppf://pair?...）
///   PPASS_E2E_DIR=container  真机用：状态文件写进 App 容器的 Documents/e2e（经 devicectl 拉回）
///   PPASS_E2E_ALBUM=smallest 只备份张数最少的非空相册（真机上有用户的真照片，不整库备份）；
///                            张数超过 PPASS_E2E_MAX_ASSETS（默认 12）就拒绝并报错
///   同时用独立的 PhotoKit 读取路径（PHAssetResourceManager，只读）算「手机原始字节」的 BLAKE3，写进 `originals`。
/// 驱动走的是真实端口（Backend / AppModel）：配对 → 选全部相册 → 前台备份 → 时间线取页，与用户点界面走同一条代码路径；
/// 只是把「点」换成了函数调用（不用 XCUITest：授权弹窗、扫码、选相册的坐标点击在本机模拟器上很脆，见 e2e-sim.sh 头注释）。
@MainActor
enum E2EDriver {
    static var requested: Bool { ProcessInfo.processInfo.environment["PPASS_E2E_DIR"] != nil }

    static func run(model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        guard var dir = env["PPASS_E2E_DIR"] else { return }
        if dir == "container" {
            dir = NSHomeDirectory() + "/Documents/e2e"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        let link = env["PPASS_E2E_PAIR_LINK"] ?? ""
        let timeoutSecs = Double(env["PPASS_E2E_TIMEOUT"] ?? "") ?? 120
        let pick = env["PPASS_E2E_ALBUM"] ?? ""
        let maxAssets = Int(env["PPASS_E2E_MAX_ASSETS"] ?? "") ?? 12
        // 后台任务模拟（tools/ios/sim-bg-task.sh）的几种模式见 BGTestDriver。
        if BGTestDriver.run(model: model, dir: URL(fileURLWithPath: dir), env: env) { return }
        Task { await drive(model: model, dir: URL(fileURLWithPath: dir), link: link, timeoutSecs: timeoutSecs, pick: pick, maxAssets: maxAssets) }
    }

    private static func drive(model: AppModel, dir: URL, link: String, timeoutSecs: Double,
                              pick: String, maxAssets: Int) async {
        var status: [String: Any] = ["step": "started"]
        func write(_ step: String, _ extra: [String: Any] = [:]) {
            status["step"] = step
            for (k, v) in extra { status[k] = v }
            if let data = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys, .prettyPrinted]) {
                try? data.write(to: dir.appendingPathComponent("status.json"), options: .atomic)
            }
        }
        let backend = model.backend
        write("started", ["is_demo": backend.isDemo, "run": ProcessInfo.processInfo.environment["PPASS_E2E_RUN"] ?? ""])

        let access = await backend.media.requestAccess()
        write("access", ["access": "\(access)"])
        guard access == .full else { write("failed", ["error": "photo access is \(access), need full", "done": true]); return }

        let outcome = await backend.pairing.pair(code: link)
        write("paired", ["pair_outcome": "\(outcome)"])
        guard case .joined(let firstTime) = outcome else { write("failed", ["error": "pairing: \(outcome)", "done": true]); return }
        model.paired(firstTime: firstTime)

        let albums: [AlbumBucket]
        do { albums = try await backend.media.albums() } catch {
            write("failed", ["error": "albums: \(error)", "done": true]); return
        }
        write("albums", ["albums": albums.map { "\($0.name ?? "?"):\($0.count)" }])
        var chosen = albums
        if pick == "smallest" {
            guard let one = albums.filter({ $0.count > 0 }).min(by: { $0.count < $1.count }) else {
                write("failed", ["error": "no non-empty album", "done": true]); return
            }
            guard one.count <= maxAssets else {
                write("failed", ["error": "smallest album has \(one.count) assets > max \(maxAssets); refusing", "done": true]); return
            }
            chosen = [one]
            write("album_picked", ["picked_album": "\(one.name ?? "?"):\(one.count)"])
        }
        let ids = Set(chosen.map(\.id))
        let originals = await originalHashes(albumIds: ids, dir: dir)
        write("originals", ["originals": originals])
        model.albumsChosen(ids, known: ids, firstTime: firstTime)

        let deadline = Date().addingTimeInterval(timeoutSecs)
        var last: FlowFacts?
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let f = backend.engine.facts()
            last = f
            write("backing_up", ["confirmed": f.confirmed, "in_scope_total": f.inScopeTotal ?? -1, "failed": f.failed,
                                 "unfinished": f.unfinished, "state": "\(f.state)", "wait_reason": "\(String(describing: f.waitReason))"])
            if let total = f.inScopeTotal, total > 0, f.confirmed >= total, f.unfinished == 0 { break }
        }
        guard let f = last, let total = f.inScopeTotal, f.confirmed >= total, total > 0 else {
            write("failed", ["error": "backup did not finish before timeout", "done": true]); return
        }

        // 时间线：daemon 入库索引是异步的，取页直到能看到全部（有界）。
        var items: [TimelineItem] = []
        var timelineError: String?
        while Date() < deadline {
            do {
                items = try await backend.timeline.page(cursor: nil, reason: .e2e).items
                timelineError = nil
                if Int64(items.count) >= total { break }
            } catch { timelineError = String(describing: error) }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        var thumbOK = 0
        for item in items.prefix(3) { if (try? await backend.timeline.thumbnail(item, large: false)) != nil { thumbOK += 1 } }
        model.refresh()
        write("done", ["done": true, "ok": Int64(items.count) >= total, "timeline_count": items.count,
                       "timeline_ids": items.map(\.id), "timeline_error": timelineError ?? "", "thumbnails_ok": thumbOK,
                       "total": total, "confirmed": f.confirmed])
    }

    /// 独立于备份引擎的只读路径：PHAssetResourceManager 把原始资源写到临时文件 → FFI 算 BLAKE3 → 删临时文件。
    private static func originalHashes(albumIds: Set<String>, dir: URL) async -> [[String: Any]] {
        let library = PhotoKitLibrary()
        var assetIds = Set<String>()
        for a in albumIds { assetIds.formUnion(library.assetIdentifiers(inCollection: a) ?? []) }
        var out: [[String: Any]] = []
        let tmp = dir.appendingPathComponent("orig-check", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(assetIds), options: nil)
        var list: [PHAsset] = []
        assets.enumerateObjects { a, _, _ in list.append(a) }
        for asset in list {
            let resources = PHAssetResource.assetResources(for: asset)
            let index = selectOriginalResource(types: resources.map(\.type), mediaType: asset.mediaType) ?? 0
            guard resources.indices.contains(index) else { continue }
            let res = resources[index]
            let url = tmp.appendingPathComponent(UUID().uuidString)
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            let err: Error? = await withCheckedContinuation { c in
                PHAssetResourceManager.default().writeData(for: res, toFile: url, options: options) { c.resume(returning: $0) }
            }
            if let err { out.append(["file": res.originalFilename, "error": "\(err)"]); continue }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
            let hash = (try? blake3FileHex(path: url.path)) ?? ""
            try? FileManager.default.removeItem(at: url)
            out.append(["file": res.originalFilename, "size": size ?? -1, "blake3": hash])
        }
        return out
    }
}
#endif
