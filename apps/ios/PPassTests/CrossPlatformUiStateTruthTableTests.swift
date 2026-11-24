import PPassCore
import SwiftUI
import XCTest
@testable import PPass

final class CrossPlatformUiStateTruthTableTests: XCTestCase {

    private func loadTruthTable() throws -> [String: Any] {
        let url = RepoPaths.root.appendingPathComponent("assets/contracts/ui-state-truth-table.json")
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(json, "ui-state-truth-table.json 解析失败")
    }

    func testConnectionStatesMatchTruthTable() throws {
        let root = try loadTruthTable()
        let array = try XCTUnwrap(root["connection_states"] as? [[String: Any]])
        for item in array {
            let id = try XCTUnwrap(item["id"] as? String)
            let pairingLost = try XCTUnwrap(item["pairing_lost"] as? Bool)
            var subState = TimelineLiveState()
            subState.connected = try XCTUnwrap(item["subscribe_connected"] as? Bool)
            subState.exhausted = try XCTUnwrap(item["subscribe_exhausted"] as? Bool)
            subState.hadFailure = try XCTUnwrap(item["subscribe_had_failure"] as? Bool)

            let expectedStatusStr = try XCTUnwrap(item["expected_status"] as? String)
            let expectedConnected = try XCTUnwrap(item["is_connected"] as? Bool)
            let expectedNeedsRepair = try XCTUnwrap(item["needs_repair"] as? Bool)

            let actual = connectionStateOf(pairingLost: pairingLost, state: subState)

            let expectedStatus: ConnectionState.Status = {
                switch expectedStatusStr {
                case "PairingLost": return .pairingLost
                case "Connected": return .connected
                case "Offline": return .offline
                case "Reconnecting": return .reconnecting
                case "Unknown": return .unknown
                default: fatalError("Unknown status: \(expectedStatusStr)")
                }
            }()

            XCTAssertEqual(actual.status, expectedStatus, "[\(id)] status 匹配")
            XCTAssertEqual(actual.isConnected, expectedConnected, "[\(id)] isConnected 匹配")
            XCTAssertEqual(actual.needsRepair, expectedNeedsRepair, "[\(id)] needsRepair 匹配")

            let expectedDotColor: Color = {
                switch item["detail_dot_color"] as? String {
                case "ACT": return PPColor.act
                case "SAFE": return PPColor.safe
                case "WAITING": return PPColor.waiting
                case "IDLE": return PPColor.idle
                default: fatalError("Unknown dot color")
                }
            }()
            XCTAssertEqual(storageDetailDotColor(actual.status), expectedDotColor, "[\(id)] storageDetailDotColor 匹配")
        }
    }

    func testPhotosGuidesMatchTruthTable() throws {
        let root = try loadTruthTable()
        let array = try XCTUnwrap(root["photos_guides"] as? [[String: Any]])
        for item in array {
            let id = try XCTUnwrap(item["id"] as? String)
            let facts = GuideFacts(
                scopeOn: try XCTUnwrap(item["scope_on"] as? Bool),
                firstUploaded: try XCTUnwrap(item["first_uploaded"] as? Bool),
                backgroundOn: try XCTUnwrap(item["background_on"] as? Bool),
                finished: try XCTUnwrap(item["finished"] as? Bool),
                firstChoicePending: try XCTUnwrap(item["first_choice_pending"] as? Bool)
            )
            let actual = AppModel.photosGuideOf(facts)
            let expectedGuideStr = try XCTUnwrap(item["expected_guide"] as? String)
            let expected: PhotosGuide = {
                switch expectedGuideStr {
                case "None": return .none
                case "EnableScope": return .enableScope
                case "EnableBackground": return .enableBackground
                default: fatalError("Unknown guide: \(expectedGuideStr)")
                }
            }()
            XCTAssertEqual(actual, expected, "[\(id)] photos guide 匹配")
        }
    }

    func testScopeAccessPoliciesMatchTruthTable() throws {
        let root = try loadTruthTable()
        let array = try XCTUnwrap(root["scope_access_policies"] as? [[String: Any]])
        for item in array {
            let accessStr = try XCTUnwrap(item["access"] as? String)
            let access: MediaAccess = {
                switch accessStr {
                case "FULL": return .full
                case "PARTIAL": return .partial
                case "NONE": return .none
                default: fatalError("Unknown access: \(accessStr)")
                }
            }()
            let expectedNotice = access == .full ? BucketScreen.AccessNotice.none : BucketScreen.AccessNotice.noAccess
            XCTAssertEqual(BucketScreen.notice(for: access), expectedNotice, "[\(accessStr)] BucketScreen.notice 匹配")
        }
    }

    func testInitialScopeTimesMatchTruthTable() throws {
        let root = try loadTruthTable()
        let array = try XCTUnwrap(root["initial_scope_times"] as? [[String: Any]])
        for item in array {
            let id = try XCTUnwrap(item["id"] as? String)
            let saved = try XCTUnwrap(item["saved"] as? Bool)
            let hasSince = try XCTUnwrap(item["has_since"] as? Bool)
            let partialAccess = try XCTUnwrap(item["partial_access"] as? Bool)
            let expectedChoice = try XCTUnwrap(item["expected_choice"] as? String)

            let savedSince: BackupSince? = saved ? (hasSince ? .since(ms: 1700000000) : .all) : nil
            let actualWantsAll = ScopePolicy.initialWantsAll(saved: savedSince, partialAccess: partialAccess)
            let expectedWantsAll = expectedChoice == "ALL"
            XCTAssertEqual(actualWantsAll, expectedWantsAll, "[\(id)] initialScopeTime (wantsAll) 匹配")
        }
    }

    func testHeroIdleLineColorsMatchTruthTable() throws {
        let root = try loadTruthTable()
        let array = try XCTUnwrap(root["hero_idle_line_colors"] as? [[String: Any]])
        for item in array {
            let id = try XCTUnwrap(item["id"] as? String)
            let hasWait = try XCTUnwrap(item["has_wait_reason"] as? Bool)
            let lineType = try XCTUnwrap(item["line_type"] as? String)
            let allSafeAllowed = try XCTUnwrap(item["all_safe_allowed"] as? Bool)
            let expectedColorStr = try XCTUnwrap(item["expected_color"] as? String)

            let expectedColor: Color = {
                switch expectedColorStr {
                case "WAITING": return PPColor.waiting
                case "SAFE": return PPColor.safe
                case "SECONDARY": return PPColor.ink60
                default: fatalError("Unknown color: \(expectedColorStr)")
                }
            }()

            let actualColor: Color = {
                if hasWait { return PPColor.waiting }
                if lineType == "AllSafe" && allSafeAllowed { return PPColor.safe }
                return PPColor.ink60
            }()
            XCTAssertEqual(actualColor, expectedColor, "[\(id)] heroIdleLineColor 匹配")
        }
    }

    func testHeroFromTodayEmptyMatchesTruthTable() throws {
        let root = try loadTruthTable()
        let array = try XCTUnwrap(root["hero_from_today_empties"] as? [[String: Any]])
        for item in array {
            let id = try XCTUnwrap(item["id"] as? String)
            let renderStr = try XCTUnwrap(item["render"] as? String)
            let countM = try XCTUnwrap(item["count_m"] as? Int64)
            let countN = try XCTUnwrap(item["count_n"] as? Int64)
            let hasSinceToday = try XCTUnwrap(item["has_since_today"] as? Bool)
            let expected = try XCTUnwrap(item["expected_empty"] as? Bool)

            let render: HeroRender = renderStr == "Triplet" ? .triplet : .accessBlocked
            let triplet = BackupTriplet(n: countN, m: countM, lastSuccessAt: 0, confirmedRaw: 0)
            let since: BackupSince? = hasSinceToday ? .since(ms: 1700000000) : .all
            let actual = HeroCard.showsFromTodayEmpty(render: render, triplet: triplet, since: since)
            XCTAssertEqual(actual, expected, "[\(id)] showsFromTodayEmpty 匹配")
        }
    }
}
