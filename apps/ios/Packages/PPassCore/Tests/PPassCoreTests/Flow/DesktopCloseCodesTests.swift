import Foundation
import XCTest
@testable import PPassCore

/// #1122 / #1119：契约——本端的关闭码常量 / 判据与 Rust 注册表快照一致（关闭码唯一定义在 `crates/proto/src/close_codes.rs`）。
final class DesktopCloseCodesContractTests: XCTestCase {
    func testRegistryMatchesRustSnapshot() throws {
        let rust = try ProtoJSON.decode([CloseCodeEntry].self, from: RepoFixtures.goldenBody("snapshots__close_codes_registry"))
        XCTAssertEqual(DesktopCloseCodes.registry.map { CloseCodeEntry(code: $0.code, reason: $0.reason) }, rust,
                       "本端注册表必须与 close_codes_registry 快照逐行一致")
    }

    /// 判据：快照里的每个码都算「未配对」；快照外的码（含 blobs 的 403、0、邻近值）都不算（反证）。
    func testMeansNotPairedIsExactlyTheSnapshotCodes() throws {
        let rust = try ProtoJSON.decode([CloseCodeEntry].self, from: RepoFixtures.goldenBody("snapshots__close_codes_registry"))
        let codes = Set(rust.map(\.code))
        for code in codes { XCTAssertTrue(DesktopCloseCodes.meansNotPaired(code), "\(code)") }
        for code in [UInt64(0), 1, 400, 402, 403, 409, 411, 500, UInt64.max] where !codes.contains(code) {
            XCTAssertFalse(DesktopCloseCodes.meansNotPaired(code), "\(code)")
        }
    }
}

/// #1122：关闭帧 → 「未配对」的判定（含关闭方核对）与它汇入既有「被拒」归类。
final class DesktopCloseRejectionTests: XCTestCase {
    private let daemon = String(repeating: "ab", count: 32)
    private let stranger = String(repeating: "cd", count: 32)

    func testRecordedDesktopClosingWithNotPairedCodesIsPairingLost() throws {
        for code in DesktopCloseCodes.registry.map(\.code) {
            let rejected = try XCTUnwrap(desktopRejection(forClose: PeerClosedConnection(nodeId: daemon, code: code), recordedDaemonNodeId: daemon, method: "hello"), "\(code)")
            XCTAssertEqual(rejected.reason, .registered(.notPaired))
            XCTAssertTrue(rejected.isPairingLost)
            // 与应答 `not_paired` 同一条归类：投递失败 → 配对失效。
            XCTAssertEqual(classifyDeliveryFailure(rejected), .pairingLost)
        }
    }

    func testNodeIdComparisonIgnoresHexCase() {
        XCTAssertNotNil(desktopRejection(forClose: PeerClosedConnection(nodeId: daemon.uppercased(), code: 401), recordedDaemonNodeId: daemon, method: "hello"))
    }

    // 反证：关闭方不是记录的那台电脑 → 不是未配对。
    func testCloseFromAnotherNodeIsNotPairingLost() {
        for code in [UInt64(401), 410] {
            XCTAssertNil(desktopRejection(forClose: PeerClosedConnection(nodeId: stranger, code: code), recordedDaemonNodeId: daemon, method: "hello"))
        }
    }

    // 反证：没有记录 / 记录为空白，没有可核对的对象。
    func testNoRecordedDesktopMeansNoRejection() {
        XCTAssertNil(desktopRejection(forClose: PeerClosedConnection(nodeId: daemon, code: 401), recordedDaemonNodeId: nil, method: "hello"))
        XCTAssertNil(desktopRejection(forClose: PeerClosedConnection(nodeId: daemon, code: 401), recordedDaemonNodeId: "  ", method: "hello"))
    }

    // 反证：未知关闭码（含 blobs 的 403）即使来自记录的电脑也不触发。
    func testUnknownCloseCodesFromRecordedDesktopAreNotPairingLost() {
        for code in [UInt64(0), 403, 400, 500, 1] {
            XCTAssertNil(desktopRejection(forClose: PeerClosedConnection(nodeId: daemon, code: code), recordedDaemonNodeId: daemon, method: "hello"), "\(code)")
        }
    }

    // 反证：没翻译的 PeerClosedConnection 本身按「连不上」归类（路径失败），不会被误当成未配对。
    func testUntranslatedPeerClosedIsPathFailure() {
        XCTAssertEqual(classifyDeliveryFailure(PeerClosedConnection(nodeId: daemon, code: 403)), .pathFailure("network:PeerClosedConnection"))
    }
}
