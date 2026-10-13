#if DEBUG
import Foundation
import PPassCore
import UIKit

/// 仅 DEBUG：模拟器端到端（tools/ios/e2e-sim.sh）的驱动。
///
/// 用环境变量启用（`SIMCTL_CHILD_` 前缀经 `simctl launch` 传入）：
///   PPASS_E2E_DIR        状态文件目录（`status.json` 每一步原子重写；`done` = 跑完）
///   PPASS_E2E_PAIR_LINK  配对串（ppf://pair?...）
/// 驱动走的是真实端口（Backend / AppModel）：配对 → 选全部相册 → 前台备份 → 时间线取页，与用户点界面走同一条代码路径；
/// 只是把「点」换成了函数调用（不用 XCUITest：授权弹窗、扫码、选相册的坐标点击在本机模拟器上很脆，见 e2e-sim.sh 头注释）。
@MainActor
enum E2EDriver {
    static var requested: Bool { ProcessInfo.processInfo.environment["PPASS_E2E_DIR"] != nil }

    static func run(model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["PPASS_E2E_DIR"] else { return }
        let link = env["PPASS_E2E_PAIR_LINK"] ?? ""
        let timeoutSecs = Double(env["PPASS_E2E_TIMEOUT"] ?? "") ?? 120
        Task { await drive(model: model, dir: URL(fileURLWithPath: dir), link: link, timeoutSecs: timeoutSecs) }
    }

    private static func drive(model: AppModel, dir: URL, link: String, timeoutSecs: Double) async {
        var status: [String: Any] = ["step": "started"]
        func write(_ step: String, _ extra: [String: Any] = [:]) {
            status["step"] = step
            for (k, v) in extra { status[k] = v }
            if let data = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys, .prettyPrinted]) {
                try? data.write(to: dir.appendingPathComponent("status.json"), options: .atomic)
            }
        }
        let backend = model.backend
        write("started", ["is_demo": backend.isDemo])

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
        let ids = Set(albums.map(\.id))
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
                items = try await backend.timeline.page(cursor: nil).items
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
}
#endif
