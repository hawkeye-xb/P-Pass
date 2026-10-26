// #338 验收 5 + MOB-95 门禁的 iOS 对位：断开按清单执行；存储根下每个文件都必须登记。
import Foundation
import XCTest
@testable import PPassCore

private struct NullSubmitter: BackgroundTaskSubmitter {
    func submit(_ spec: BackgroundTaskRequestSpec) throws {}
    func submitShort(earliestBeginDate: Date) throws {}
    func cancelAll() {}
}

private final class RecordingRuntime: DisconnectRuntime {
    var calls: [String] = []
    func stopFlowRuntime() { calls.append("flow") }
    func cancelScheduledWakes() { calls.append("wakes") }
    func stopMediaChangeObserver() { calls.append("media") }
    func clearThumbnailMemoryCache() { calls.append("thumbs") }
}

final class DisconnectManifestTests: XCTestCase {

    /// 真跑全部 store 的写入，再加上 App 层（配对 / 身份 / 原生仓库）放的东西，模拟一个「用过一阵」的存储根。
    private func populate(_ root: URL) throws {
        try AutoBackupPrefs(directory: root).setEnabled(true)
        try AutoBackupPrefs(directory: root).setRequested(true)
        try BackupSettings(directory: root).save(wifiOnly: false)
        try NotifyOnFailurePrefs(directory: root).setEnabled(false)
        try OnboardedDesktopsStore(directory: root).markOnboarded("node-a")
        let ask = OnboardingNotificationAsk(directory: root)
        ask.initIfAbsent(existingUser: false)
        try ask.markAsked()
        try DefinitiveNoticeStore(directory: root).save(DefinitiveNoticeState(notifiedLostPairingId: "e"))
        try SentinelStore(directory: root).recordReachable(now: 1)
        try SavedToGalleryStore(directory: root).remember(hash: "h", localIdentifier: "L")
        try BackupScopeStore(directory: root, daemonNodeId: nil).saveScope(selected: ["x"], allCurrent: ["x"])
        try BackupScopeStore(directory: root, daemonNodeId: "node-a").saveScope(selected: ["a"], allCurrent: ["a"])
        let flow = FlowControlStore(directory: root)
        flow.setPaused(true)
        flow.setWaitReason(.wifi)
        let orders = try SQLiteOrderStore(directory: root)
        try orders.claimOwner("node-a", idFloor: 0)
        try orders.insert(NewOrder(mediaId: "m1", sourceVersion: "v", bucketId: "a", contentHash: "h", state: .confirmed, pairingId: "e"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("pairing.json"))
        PlannedWakeScheduler(directory: root, submitter: NullSubmitter(), logger: NoopLogger()).scheduleUnreachableProbes()
        try Data([1, 2, 3]).write(to: root.appendingPathComponent(DeviceIdentity.legacyPlaintextFileName))
        try Data().write(to: root.appendingPathComponent(DeviceIdentity.markerFileName))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("iroh-blobs-provider/data"), withIntermediateDirectories: true)
        try Data([0]).write(to: root.appendingPathComponent("iroh-blobs-provider/data/blob"))
    }

    /// #974：某一行（这里是配对凭据）清不掉，后面的运行时停止行仍要执行；错误在最后抛出，不吞。
    /// stopFlowRuntime 现在承担 provider 撤销（revoke + 清允许对端），不能被前一行的失败短路。
    /// 反证：把 catch 改回原来的「首错即抛」，runtime.calls 为空，红。
    func testARowThatFailsDoesNotSkipTheRuntimeStopsAfterIt() throws {
        let tmp = TempDir()
        let stuck = tmp.file("pairing.json")
        try FileManager.default.createDirectory(at: stuck, withIntermediateDirectories: true)
        try Data([1]).write(to: stuck.appendingPathComponent("inner"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: stuck.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stuck.path) }
        let runtime = RecordingRuntime()
        XCTAssertThrowsError(try applyDisconnectManifest(root: tmp.url, runtime: runtime))
        XCTAssertEqual(Set(runtime.calls), ["flow", "wakes", "media", "thumbs"], "前面的行失败，运行时停止行照常执行")
    }

    /// 门禁：每一样落盘的状态都在清单里（含 SQLite 的 -wal / -shm 伴生文件）。
    /// 反证：新增一个不登记的文件，这里列出它，红。
    func testEveryPersistedFileIsRegistered() throws {
        let tmp = TempDir()
        try populate(tmp.url)
        XCTAssertEqual(unregisteredStatePaths(root: tmp.url), [])
        tmp.write("stray-new-store.json", "{}")
        XCTAssertEqual(unregisteredStatePaths(root: tmp.url), ["stray-new-store.json"])
    }

    /// 断开：配对作废、停生产者（三个运行时）、自动备份停生产者留意图；其余（范围、账本、身份、连过的桌面……）原样留着。
    func testDisconnectAppliesEveryRow() throws {
        let tmp = TempDir()
        try populate(tmp.url)
        let runtime = RecordingRuntime()
        try applyDisconnectManifest(root: tmp.url, runtime: runtime)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.file("pairing.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.file(PlannedWakeScheduler.fileName).path), "唤醒计划随断开清掉")
        XCTAssertEqual(runtime.calls, ["flow", "wakes", "media", "thumbs"], "清单顺序就是执行顺序")
        XCTAssertFalse(AutoBackupPrefs(directory: tmp.url).enabled())
        XCTAssertTrue(AutoBackupPrefs(directory: tmp.url).requested())
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.file(DeviceIdentity.markerFileName).path), "本次安装的标记留着：断开后再配对还是同一台手机")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.file(DeviceIdentity.legacyPlaintextFileName).path), "旧明文私钥随断开清掉")
        // #1152：「保存到相册」去重记录随断开清掉。反证：savedToGallery 行改成 .keep ⇒ 红。
        XCTAssertNil(SavedToGalleryStore(directory: tmp.url).localIdentifier(for: "h"), "保存到相册的记录随断开清掉")
        XCTAssertTrue(OnboardedDesktopsStore(directory: tmp.url).wasOnboarded("node-a"))
        XCTAssertEqual(try BackupScopeStore(directory: tmp.url, daemonNodeId: "node-a").selectedBucketIds(), ["a"])
        XCTAssertFalse(BackupSettings(directory: tmp.url).wifiOnly())
        XCTAssertTrue(FlowControlStore(directory: tmp.url).paused(), "待拍板行：现状保留")
        XCTAssertEqual(try SQLiteOrderStore(directory: tmp.url).currentOrders().collect().count, 1, "连回同一台桌面 CONFIRMED 仍有效")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.file("iroh-blobs-provider/data/blob").path))
    }

    // MARK: 原图缓存（#1119）：存储根之外的 Caches / tmp

    private struct Roots {
        let root = TempDir(), caches = TempDir(), tmp = TempDir()
        var external: DisconnectExternalRoots { DisconnectExternalRoots(caches: caches.url, tmp: tmp.url) }
        func exists(_ dir: TempDir, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: dir.file(rel).path) }
    }

    private func populateOriginalCaches(_ r: Roots) throws {
        let fm = FileManager.default
        for rel in ["ppass-videos/abc.mov", "ppass-videos/def.mov.part"] {
            try fm.createDirectory(at: r.caches.file(rel).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: r.caches.file(rel))
        }
        for rel in ["ppass-share/p.jpg", "ppass-blobstore/data/blob", "ppass-originals/mine.heic"] {
            try fm.createDirectory(at: r.tmp.file(rel).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: r.tmp.file(rel))
        }
        try Data([1]).write(to: r.caches.file("system-owned.db"))
        try Data([1]).write(to: r.tmp.file("system-owned.tmp"))
    }

    /// 断开清掉视频原图缓存（含 .part）、照片原图临时目录、取回临时仓库；不碰系统自己的文件，也不碰备份导入器的临时目录。
    /// 反证：把 originalVideoCache / originalShareTemp / fetchScratch 任一行改成 .keep，对应断言红；
    /// 把清除范围放大成整个 Caches / tmp，system-owned 两条红。
    func testDisconnectClearsTheOriginalCachesOutsideTheStorageRoot() throws {
        let r = Roots()
        try populateOriginalCaches(r)
        try applyDisconnectManifest(root: r.root.url, runtime: RecordingRuntime(), external: r.external)
        XCTAssertFalse(r.exists(r.caches, "ppass-videos"), "视频原图缓存整目录清掉（含 .part）")
        XCTAssertFalse(r.exists(r.tmp, "ppass-share"))
        XCTAssertFalse(r.exists(r.tmp, "ppass-blobstore"))
        XCTAssertTrue(r.exists(r.tmp, "ppass-originals/mine.heic"), "导入器临时目录是手机自己的照片，不碰")
        XCTAssertTrue(r.exists(r.caches, "system-owned.db"))
        XCTAssertTrue(r.exists(r.tmp, "system-owned.tmp"))
    }

    /// 不给外部根就不碰（包测试跑在开发机上，不许误删真缓存）。
    func testWithoutExternalRootsTheCachesAreNotTouched() throws {
        let r = Roots()
        try populateOriginalCaches(r)
        try applyDisconnectManifest(root: r.root.url, runtime: RecordingRuntime())
        XCTAssertTrue(r.exists(r.caches, "ppass-videos/abc.mov"))
        XCTAssertTrue(r.exists(r.tmp, "ppass-share/p.jpg"))
    }

    /// 门禁也盯 Caches / tmp 里 ppass- 开头的目录：新加的缓存目录不登记就过不了。
    /// 反证：删掉 originalVideoCache 这一行，门禁把 caches:ppass-videos 列出来，红。
    func testTheGateCoversTheOriginalCacheDirectories() throws {
        let r = Roots()
        try populateOriginalCaches(r)
        XCTAssertEqual(unregisteredStatePaths(root: r.root.url, external: r.external), [])
        try FileManager.default.createDirectory(at: r.caches.file("ppass-new-cache"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: r.tmp.file("ppass-new-temp"), withIntermediateDirectories: true)
        XCTAssertEqual(unregisteredStatePaths(root: r.root.url, external: r.external), ["caches:ppass-new-cache", "tmp:ppass-new-temp"])
        let without = DisconnectState.allCases.filter { $0 != .originalVideoCache }
        XCTAssertTrue(unregisteredStatePaths(root: r.root.url, manifest: without, external: r.external).contains("caches:ppass-videos"))
    }

    func testRowMatchingCoversCompanionsButNotLookalikes() {
        XCTAssertTrue(DisconnectState.orderDB.matches("backup-orders.db-wal"))
        XCTAssertTrue(DisconnectState.orderDB.matches("backup-orders.db"))
        XCTAssertFalse(DisconnectState.orderDB.matches("backup-orders.dbx"))
        XCTAssertTrue(DisconnectState.backupScope.matches("backup_scope-node123.json"))
        XCTAssertFalse(DisconnectState.backupScope.matches("backup_scope.json"))
        XCTAssertTrue(DisconnectState.backupScopeUnpaired.matches("backup_scope.json"))
        XCTAssertTrue(DisconnectState.nativeBlobStore.matches("iroh-blobs-provider/data/blob"))
        XCTAssertFalse(DisconnectState.flowRuntime.matches("anything"))
    }

    /// 每一行都有依据，CLEAR / RESET / STOP 只出现在定过语义的行上。
    func testEveryRowHasABasis() {
        for row in DisconnectState.allCases {
            XCTAssertFalse(row.basis.isEmpty, "\(row)")
            if row.basis.hasPrefix(undecidedBasis) { XCTAssertEqual(row.disposition, .keep, "\(row)：待拍板的行只能是现状（不碰）") }
            XCTAssertEqual(row.path == nil, row.disposition == .stop, "\(row)：运行时行没有路径，落盘行一定有")
        }
    }
}
