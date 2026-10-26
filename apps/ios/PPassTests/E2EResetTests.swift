// PPASS_E2E_RESET 清的是 StorageRoot 解析出来的真实根（App Group 容器里的 PPass/），不是写死的 Application Support/PPass。
import PPassCore
import XCTest
@testable import PPass

final class E2EResetTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-reset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    func testWipesTheAppGroupRootAndTheIdentity() throws {
        let group = base.appendingPathComponent("group", isDirectory: true)
        let support = base.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        let root = try StorageRoot.resolve(appGroupContainer: group, groupIdentifier: "group.test", appPrivateDirectory: support, logger: NullLogger())
        XCTAssertEqual(root.kind, .appGroup)
        try Data("{}".utf8).write(to: root.url.appendingPathComponent("pairing.json"))
        let identity = MemoryIdentity()
        try identity.write(Data(repeating: 1, count: 32))
        let log = Lines()

        E2EReset.wipe(root: root, identity: identity, logger: log)

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.url.path), "App Group 里的存储根必须删掉")
        XCTAssertNil(try identity.read())
        XCTAssertTrue(log.lines.contains { $0.contains("removed storage root") && $0.contains("(app group)") }, "\(log.lines)")
    }

    func testDegradedRootIsTheOneWiped() throws {
        let support = base.appendingPathComponent("support", isDirectory: true)
        let root = try StorageRoot.resolve(appGroupContainer: nil, groupIdentifier: "group.test", appPrivateDirectory: support, logger: NullLogger())
        let log = Lines()
        E2EReset.wipe(root: root, identity: MemoryIdentity(), logger: log)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.url.path))
        XCTAssertTrue(log.lines.contains { $0.contains("(app-private fallback)") }, "\(log.lines)")
    }
}

private final class MemoryIdentity: IdentitySecretStore, @unchecked Sendable {
    private var key: Data?
    func read() throws -> Data? { key }
    func write(_ key: Data) throws { self.key = key }
    func delete() throws { key = nil }
}

private final class Lines: CoreLogger, @unchecked Sendable {
    private(set) var lines: [String] = []
    func log(_ message: String) { lines.append(message) }
}
