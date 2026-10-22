// 身份私钥进钥匙串（对位 Android Keystore 加固）：什么时候照常用、什么时候按新设备换一把，
// 以及每一步失败时什么都不删。钥匙串用内存假实现，按操作注入失败；存储根是真目录。
import Foundation
import XCTest
@testable import PPassCore

final class DeviceIdentityTests: XCTestCase {
    private let keyA = Data(repeating: 0xA1, count: 32)
    private let keyB = Data(repeating: 0xB2, count: 32)

    // MARK: 照常

    /// 有私钥、有标记、没有明文：原样返回，不碰配对。
    /// 反证：把「有标记」分支改成走新设备，outcome 变 .newDevice、配对被清，红。
    func testExistingKeyWithMarkerIsUsedAsIs() throws {
        let tmp = TempDir()
        let store = FakeStore(item: keyA)
        try markInstalled(tmp)
        try pair(tmp)
        let cleared = Counter()
        let loaded = try load(tmp, store, cleared)
        XCTAssertEqual(loaded, .init(key: keyA, outcome: .existing))
        XCTAssertEqual(cleared.count, 0)
        XCTAssertEqual(store.writes, 0)
    }

    // MARK: 新设备的四种来源

    /// 全新安装 / 备份恢复：钥匙串里没有 → 生成、写入、读回、写标记；没有配对就不调清理。
    func testMissingKeyCreatesOne() throws {
        let tmp = TempDir()
        let store = FakeStore(item: nil)
        let cleared = Counter()
        let loaded = try load(tmp, store, cleared, random: keyB)
        XCTAssertEqual(loaded, .init(key: keyB, outcome: .newDevice(.missing)))
        XCTAssertEqual(store.item, keyB)
        XCTAssertTrue(exists(tmp, DeviceIdentity.markerFileName))
        XCTAssertEqual(cleared.count, 0, "没有配对记录，不跑断开清单")
    }

    /// 备份恢复（备份排除没生效）/ 钥匙串被清：没有私钥但有配对记录 → 新私钥 + 清配对。
    /// 反证：去掉 becomeNewDevice 里的 clearPairing，cleared.count 为 0，红。
    func testMissingKeyWithPairingClearsThePairing() throws {
        let tmp = TempDir()
        let store = FakeStore(item: nil)
        try pair(tmp)
        try markInstalled(tmp)
        let cleared = Counter()
        let loaded = try load(tmp, store, cleared, random: keyB)
        XCTAssertEqual(loaded.outcome, .newDevice(.missing))
        XCTAssertEqual(cleared.count, 1)
    }

    /// 卸载重装：钥匙串还留着旧私钥，存储根是空的（没有标记）→ 不沿用，换一把。
    /// 反证：去掉 reinstall 分支，返回旧的 keyA，红。
    func testKeyWithoutMarkerIsAReinstall() throws {
        let tmp = TempDir()
        let store = FakeStore(item: keyA)
        let loaded = try load(tmp, store, Counter(), random: keyB)
        XCTAssertEqual(loaded, .init(key: keyB, outcome: .newDevice(.reinstall)))
        XCTAssertEqual(store.item, keyB)
        XCTAssertTrue(exists(tmp, DeviceIdentity.markerFileName))
    }

    /// 测试机上的旧明文私钥：不迁移——删明文、清配对、换新私钥。
    /// 反证：把明文分支改成「读出来写进钥匙串」，key 等于明文内容、明文文件还在，红。
    func testLegacyPlaintextIsDiscardedNotMigrated() throws {
        let tmp = TempDir()
        let legacy = Data(repeating: 0x77, count: 32)
        try legacy.write(to: tmp.file(DeviceIdentity.legacyPlaintextFileName))
        try pair(tmp)
        let store = FakeStore(item: nil)
        let cleared = Counter()
        let loaded = try load(tmp, store, cleared, random: keyB)
        XCTAssertEqual(loaded, .init(key: keyB, outcome: .newDevice(.legacyPlaintext)))
        XCTAssertNotEqual(loaded.key, legacy)
        XCTAssertFalse(exists(tmp, DeviceIdentity.legacyPlaintextFileName))
        XCTAssertEqual(cleared.count, 1)
    }

    /// 明文优先于钥匙串：哪怕钥匙串里已有带标记的私钥，见到明文也当新设备（明文可能已经进过备份）。
    func testLegacyPlaintextWinsOverAnExistingKey() throws {
        let tmp = TempDir()
        try Data(repeating: 0x77, count: 32).write(to: tmp.file(DeviceIdentity.legacyPlaintextFileName))
        try markInstalled(tmp)
        let loaded = try load(tmp, FakeStore(item: keyA), Counter(), random: keyB)
        XCTAssertEqual(loaded.outcome, .newDevice(.legacyPlaintext))
    }

    func testMalformedKeyIsReplaced() throws {
        let tmp = TempDir()
        try markInstalled(tmp)
        let loaded = try load(tmp, FakeStore(item: Data([1, 2, 3])), Counter(), random: keyB)
        XCTAssertEqual(loaded, .init(key: keyB, outcome: .newDevice(.malformed)))
    }

    /// 「重置并重新配对」：不管现状，换新私钥 + 清配对。
    func testUserResetReplacesTheKeyAndClearsPairing() throws {
        let tmp = TempDir()
        try markInstalled(tmp)
        try pair(tmp)
        let store = FakeStore(item: keyA)
        let cleared = Counter()
        let loaded = try DeviceIdentity.becomeNewDevice(root: tmp.url, store: store, reason: .userReset,
                                                        clearPairing: { cleared.count += 1 }, random: { self.keyB }, logger: NoopLogger())
        XCTAssertEqual(loaded, .init(key: keyB, outcome: .newDevice(.userReset)))
        XCTAssertEqual(store.item, keyB)
        XCTAssertEqual(cleared.count, 1)
    }

    // MARK: 失败：读不到 ≠ 没有；前两步失败什么都不删

    /// 首次解锁前：原样抛 locked，不生成、不清配对、不删明文、不写标记。
    /// 反证：把 read 的 locked 当成 nil（像旧代码的 try?），会生成新私钥并清配对，红。
    func testLockedBeforeFirstUnlockTouchesNothing() throws {
        let tmp = TempDir()
        try pair(tmp)
        try Data(repeating: 0x77, count: 32).write(to: tmp.file(DeviceIdentity.legacyPlaintextFileName))
        let store = FakeStore(item: keyA)
        store.fail[.read] = .locked
        let cleared = Counter()
        XCTAssertThrowsError(try load(tmp, store, cleared)) { XCTAssertEqual($0 as? IdentityStoreError, .locked) }
        assertUntouched(tmp, store, cleared, item: keyA)
    }

    /// 其他读失败同理：原样抛出。
    func testReadFailureTouchesNothing() throws {
        let tmp = TempDir()
        try pair(tmp)
        let store = FakeStore(item: nil)
        store.fail[.read] = .failed(op: "read", status: -34018)
        let cleared = Counter()
        XCTAssertThrowsError(try load(tmp, store, cleared)) { XCTAssertEqual($0 as? IdentityStoreError, .failed(op: "read", status: -34018)) }
        assertUntouched(tmp, store, cleared, item: nil)
    }

    /// 写失败：抛出，配对、明文、标记都还在原样。
    /// 反证：把清配对挪到写钥匙串之前，cleared.count 为 1，红。
    func testWriteFailureTouchesNothing() throws {
        let tmp = TempDir()
        try pair(tmp)
        try Data(repeating: 0x77, count: 32).write(to: tmp.file(DeviceIdentity.legacyPlaintextFileName))
        let store = FakeStore(item: nil)
        store.fail[.write] = .failed(op: "write", status: -25299)
        let cleared = Counter()
        XCTAssertThrowsError(try load(tmp, store, cleared, random: keyB))
        XCTAssertEqual(cleared.count, 0)
        XCTAssertTrue(exists(tmp, "pairing.json"))
        XCTAssertTrue(exists(tmp, DeviceIdentity.legacyPlaintextFileName))
        XCTAssertFalse(exists(tmp, DeviceIdentity.markerFileName))
    }

    /// 读回不一致：抛 readBackMismatch，不清配对、不写标记。
    /// 反证：去掉读回校验，load 成功返回，红。
    func testReadBackMismatchTouchesNothing() throws {
        let tmp = TempDir()
        try pair(tmp)
        let store = FakeStore(item: nil)
        store.corruptOnWrite = true
        let cleared = Counter()
        XCTAssertThrowsError(try load(tmp, store, cleared, random: keyB)) { XCTAssertEqual($0 as? IdentityStoreError, .readBackMismatch) }
        XCTAssertEqual(cleared.count, 0)
        XCTAssertTrue(exists(tmp, "pairing.json"))
        XCTAssertFalse(exists(tmp, DeviceIdentity.markerFileName))
    }

    /// 删除旧项失败：抛出，什么都不动。
    func testDeleteFailureTouchesNothing() throws {
        let tmp = TempDir()
        try pair(tmp)
        let store = FakeStore(item: keyA)
        store.fail[.delete] = .failed(op: "delete", status: -25300)
        let cleared = Counter()
        XCTAssertThrowsError(try load(tmp, store, cleared, random: keyB))
        assertUntouched(tmp, store, cleared, item: keyA)
    }

    /// 清配对失败：抛出、不写标记——下次启动钥匙串里的新私钥没有标记，重走新设备，再清一次。
    /// 反证：把写标记挪到清配对之前，下一次 load 会照常返回、配对永远清不掉，红。
    func testClearPairingFailureRetriesOnNextLaunch() throws {
        let tmp = TempDir()
        try pair(tmp)
        let store = FakeStore(item: nil)
        struct Boom: Error {}
        XCTAssertThrowsError(try DeviceIdentity.load(root: tmp.url, store: store, clearPairing: { throw Boom() },
                                                     random: { self.keyB }, logger: NoopLogger()))
        XCTAssertFalse(exists(tmp, DeviceIdentity.markerFileName))
        let cleared = Counter()
        let next = try load(tmp, store, cleared, random: keyA)
        XCTAssertEqual(next.outcome, .newDevice(.reinstall))
        XCTAssertEqual(cleared.count, 1)
    }

    /// 标记读失败（不是「不存在」）：原样抛出，不当成重装。这里用一个读不了属性的路径构造：
    /// 存储根本身不可进入（0o000）。
    /// 反证：把 exists 改成 FileManager.fileExists（读失败 = false），会走 reinstall 换掉私钥，红。
    func testMarkerReadFailureIsNotAReinstall() throws {
        let tmp = TempDir()
        let root = tmp.file("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(DeviceIdentity.markerFileName))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        let store = FakeStore(item: keyA)
        XCTAssertThrowsError(try DeviceIdentity.load(root: root, store: store, clearPairing: {}, random: { self.keyB }, logger: NoopLogger()))
        XCTAssertEqual(store.item, keyA, "私钥没被换掉")
    }

    // MARK: 断开清单

    /// 标记是 keep（断开后再配对还是同一台手机）；旧明文是 clear。
    func testManifestKeepsTheMarkerAndClearsLegacyPlaintext() throws {
        XCTAssertEqual(DisconnectState.identity.path, DeviceIdentity.markerFileName)
        XCTAssertEqual(DisconnectState.identity.disposition, .keep)
        XCTAssertEqual(DisconnectState.legacyPlaintextIdentity.path, DeviceIdentity.legacyPlaintextFileName)
        XCTAssertEqual(DisconnectState.legacyPlaintextIdentity.disposition, .clear)
    }

    // MARK: helpers

    private func load(_ tmp: TempDir, _ store: FakeStore, _ cleared: Counter, random: Data? = nil) throws -> DeviceIdentity.Loaded {
        let key = random ?? keyB
        return try DeviceIdentity.load(root: tmp.url, store: store, clearPairing: { cleared.count += 1 }, random: { key }, logger: NoopLogger())
    }

    private func pair(_ tmp: TempDir) throws { try Data("{}".utf8).write(to: tmp.file("pairing.json")) }
    private func markInstalled(_ tmp: TempDir) throws { try Data().write(to: tmp.file(DeviceIdentity.markerFileName)) }
    private func exists(_ tmp: TempDir, _ name: String) -> Bool { FileManager.default.fileExists(atPath: tmp.file(name).path) }

    private func assertUntouched(_ tmp: TempDir, _ store: FakeStore, _ cleared: Counter, item: Data?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(store.item, item, "钥匙串没动", file: file, line: line)
        XCTAssertEqual(store.writes, 0, file: file, line: line)
        XCTAssertEqual(cleared.count, 0, "配对没清", file: file, line: line)
        XCTAssertTrue(exists(tmp, "pairing.json"), file: file, line: line)
        XCTAssertFalse(exists(tmp, DeviceIdentity.markerFileName), "没写标记", file: file, line: line)
    }
}

private final class Counter { var count = 0 }

private final class FakeStore: IdentitySecretStore, @unchecked Sendable {
    enum Op { case read, write, delete }
    var item: Data?
    var fail: [Op: IdentityStoreError] = [:]
    var corruptOnWrite = false
    var writes = 0

    init(item: Data?) { self.item = item }

    func read() throws -> Data? {
        if let e = fail[.read] { throw e }
        return item
    }

    func write(_ key: Data) throws {
        if let e = fail[.write] { throw e }
        writes += 1
        item = corruptOnWrite ? Data(key.reversed().map { $0 ^ 0xFF }) : key
    }

    func delete() throws {
        if let e = fail[.delete] { throw e }
        item = nil
    }
}
