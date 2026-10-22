// 钥匙串里那一项的真实读写（宿主 App 里跑，模拟器有真钥匙串）：属性对、读写删往返、DeviceIdentity 接上真钥匙串。
import PPassCore
import Security
import XCTest
@testable import PPass

final class KeychainIdentityStoreTests: XCTestCase {
    private var store: KeychainIdentityStore!

    override func setUp() {
        store = KeychainIdentityStore(service: "com.hawkeyexb.ppass.identity.tests.\(UUID().uuidString)")
    }

    override func tearDown() { try? store.delete() }

    func testRoundTrip() throws {
        XCTAssertNil(try store.read(), "新 service 下没有这一项")
        let key = Data(repeating: 0x5A, count: 32)
        try store.write(key)
        XCTAssertEqual(try store.read(), key)
        try store.delete()
        XCTAssertNil(try store.read())
        try store.delete() // 本来就没有不算错
    }

    /// 首次解锁后可读、仅本设备、不同步——这三样决定「不进备份、后台能读」。
    /// 反证：把 kSecAttrAccessible 改成 AfterFirstUnlock（无 ThisDeviceOnly）或把同步打开，这里红。
    func testItemAttributes() throws {
        try store.write(Data(repeating: 1, count: 32))
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: store.service,
                                    kSecAttrAccount as String: store.account, kSecReturnAttributes as String: true,
                                    kSecAttrSynchronizable as String: kSecAttrSynchronizableAny]
        var out: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &out), errSecSuccess)
        let attrs = try XCTUnwrap(out as? [String: Any])
        XCTAssertEqual(attrs[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual((attrs[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue ?? false, false)
    }

    /// 写两次（没先删）是错，不是悄悄覆盖：DeviceIdentity 总是先删再写。
    func testWriteWithoutDeleteFails() throws {
        try store.write(Data(repeating: 1, count: 32))
        XCTAssertThrowsError(try store.write(Data(repeating: 2, count: 32))) {
            XCTAssertEqual($0 as? IdentityStoreError, .failed(op: "write", status: errSecDuplicateItem))
        }
    }

    /// 接上真钥匙串：第一次生成，第二次原样读回同一把（NodeId 不变）。
    func testDeviceIdentityOverRealKeychainIsStableAcrossLaunches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("identity-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try DeviceIdentity.load(root: root, store: store, clearPairing: {}, logger: NoopLogger())
        XCTAssertEqual(first.outcome, .newDevice(.missing))
        let second = try DeviceIdentity.load(root: root, store: store, clearPairing: {}, logger: NoopLogger())
        XCTAssertEqual(second.key, first.key)
        XCTAssertEqual(second.outcome, .existing)
    }
}
