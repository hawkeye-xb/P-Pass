import Foundation
import XCTest
@testable import PPassCore

/// #1069 §2 / #1073：手机对每条应答再核一次版本（覆盖 v2 之前的电脑），所有调用方看到同一个样子。
/// 反证：去掉 `ProtoClient.callRaw` 的 `.versionChecked()`，`testEveryCallSeesAnOldDesktopAsDesktopOutdated` 红。
final class VersionCheckTests: XCTestCase {
    func testCompatibilityMirrorsRustForThePhoneRole() {
        XCTAssertNil(Resp.outdatedSide(peerVer: 2, peerMinVer: 2))
        XCTAssertNil(Resp.outdatedSide(peerVer: 3, peerMinVer: 2), "更新的电脑仍接受本端")
        XCTAssertEqual(Resp.outdatedSide(peerVer: 1, peerMinVer: 1), .desktop, "v1 电脑（缺 ver）")
        XCTAssertEqual(Resp.outdatedSide(peerVer: 3, peerMinVer: 3), .phone, "电脑不再接受本端")
    }

    func testAnOldDesktopsOkReplyBecomesAVersionRejection() throws {
        let v1 = try ProtoJSON.decode(Resp.self, from: Data(#"{"id":"1","ok":true,"result":{}}"#.utf8))
        let checked = v1.versionChecked()
        XCTAssertFalse(checked.ok)
        XCTAssertNil(checked.result)
        XCTAssertEqual(checked.error?.code, Codes.versionMismatch)
        XCTAssertEqual(checked.error?.reasonKind, .desktopOutdated)
    }

    func testTheDesktopsOwnVerdictPassesThroughAndACompatibleReplyIsUntouched() {
        let said = Resp(id: "1", ok: false, error: RespError(code: Codes.versionMismatch, reason: "phone_outdated"))
        XCTAssertEqual(said.versionChecked(), said)
        XCTAssertEqual(said.outdatedSide, .phone)
        let fine = Resp(id: "1", ok: true, result: .object([:]))
        XCTAssertEqual(fine.versionChecked(), fine)
        let other = Resp(id: "1", ok: false, error: RespError(code: Codes.notAuthorized, reason: "revoked"))
        XCTAssertEqual(other.versionChecked(), other)
        XCTAssertNil(other.outdatedSide)
    }

    private struct V1Desktop: CtrlTransport {
        func call(method: String, paramsJSON: Data, timeoutMs: UInt64?) async throws -> Data {
            Data(#"{"id":"1","ok":true,"result":{"capabilities":[]}}"#.utf8)
        }
    }

    /// 端到端：v2 之前的电脑对 hello 正常作答，探测也得判成「电脑太旧」，不是可达、不是配对失效。
    func testEveryCallSeesAnOldDesktopAsDesktopOutdated() async throws {
        let desktop = ControlPlaneDesktop(client: ProtoClient(transport: V1Desktop()))
        do {
            _ = try await desktop.hello()
            XCTFail("v1 电脑的应答必须被拒")
        } catch let rejected as DesktopRejected {
            XCTAssertEqual(rejected.reason, .registered(.desktopOutdated))
            XCTAssertEqual(rejected.reasonClass, .versionMismatch(.desktop))
            XCTAssertFalse(rejected.isPairingLost)
        }
        let probe = ControlPlaneProbe(currentEpoch: { "e1" }, desktop: desktop, logger: NoopLogger(), pairingLoss: PairingLoss())
        let result = await probe.probe()
        XCTAssertEqual(result, .versionMismatch(.desktop))
    }
}
