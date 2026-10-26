// PPASS_E2E_RESET 清的是 StorageRoot 解析出来的真实根（App 容器 Application Support 下的 PPass/）和钥匙串身份。
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

    func testWipesTheStorageRootAndTheIdentity() throws {
        let support = base.appendingPathComponent("support", isDirectory: true)
        let root = try StorageRoot.resolve(appPrivateDirectory: support, logger: NullLogger())
        try Data("{}".utf8).write(to: root.url.appendingPathComponent("pairing.json"))
        let identity = MemoryIdentity()
        try identity.write(Data(repeating: 1, count: 32))
        let log = Lines()

        E2EReset.wipe(root: root, identity: identity, logger: log)

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.url.path), "存储根必须删掉")
        XCTAssertNil(try identity.read())
        XCTAssertTrue(log.lines.contains { $0.contains("removed storage root \(root.url.path)") }, "\(log.lines)")
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
