// #338 验收 5 + MOB-95 门禁的 iOS 对位：断开按清单执行；存储根下每个文件都必须登记。
import Foundation
import XCTest
@testable import PPassCore

private struct NullSubmitter: BackgroundTaskSubmitter {
    func submit(_ spec: BackgroundTaskRequestSpec) throws {}
    func cancelAll() {}
}

private final class RecordingRuntime: DisconnectRuntime {
    var calls: [String] = []
    func stopFlowRuntime() { calls.append("flow") }
    func cancelScheduledWakes() { calls.append("wakes") }
    func stopMediaChangeObserver() { calls.append("media") }
}

final class DisconnectManifestTests: XCTestCase {

    /// 真跑全部 store 的写入，再加上 App 层（配对 / 身份 / 原生仓库）放的东西，模拟一个「用过一阵」的存储根。
    private func populate(_ root: URL) throws {
        try AutoBackupPrefs(directory: root).setEnabled(true)
        try AutoBackupPrefs(directory: root).setRequested(true)
        try BackupSettings(directory: root).save(wifiOnly: false)
        try NotifyOnFailurePrefs(directory: root).setEnabled(false)
        try OnboardedDesktopsStore(directory: root).markOnboarded("node-a")
        try SentinelStore(directory: root).recordReachable(now: 1)
        try BackupScopeStore(directory: root, daemonNodeId: nil).saveScope(selected: ["x"], allCurrent: ["x"])
        try BackupScopeStore(directory: root, daemonNodeId: "node-a").saveScope(selected: ["a"], allCurrent: ["a"])
        let flow = FlowControlStore(directory: root)
        flow.setPaused(true)
        flow.setWaitReason(.wifi)
        let orders = try SQLiteOrderStore(directory: root)
        try orders.claimOwner("node-a", idFloor: 0)
        try orders.insert(NewOrder(mediaId: "m1", sourceVersion: "v", bucketId: "a", contentHash: "h", state: .confirmed, pairingEpoch: "e"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("pairing.json"))
        PlannedWakeScheduler(directory: root, submitter: NullSubmitter(), logger: NoopLogger()).scheduleUnreachableProbes()
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("identity.key"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("iroh-blobs-provider/data"), withIntermediateDirectories: true)
        try Data([0]).write(to: root.appendingPathComponent("iroh-blobs-provider/data/blob"))
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
        XCTAssertEqual(runtime.calls, ["flow", "wakes", "media"], "清单顺序就是执行顺序")
        XCTAssertFalse(AutoBackupPrefs(directory: tmp.url).enabled())
        XCTAssertTrue(AutoBackupPrefs(directory: tmp.url).requested())
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.file("identity.key").path))
        XCTAssertTrue(OnboardedDesktopsStore(directory: tmp.url).wasOnboarded("node-a"))
        XCTAssertEqual(try BackupScopeStore(directory: tmp.url, daemonNodeId: "node-a").selectedBucketIds(), ["a"])
        XCTAssertFalse(BackupSettings(directory: tmp.url).wifiOnly())
        XCTAssertTrue(FlowControlStore(directory: tmp.url).paused(), "待拍板行：现状保留")
        XCTAssertEqual(try SQLiteOrderStore(directory: tmp.url).currentOrders().collect().count, 1, "连回同一台桌面 CONFIRMED 仍有效")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.file("iroh-blobs-provider/data/blob").path))
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
