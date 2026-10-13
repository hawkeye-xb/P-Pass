// #339 覆盖门禁：04-case-matrix 的每一行（含已废弃、含仅 iOS 的 I 组）在 iOS 上要么有同语义 XCTest，
// 要么在 06-ios-variants.zh-CN.md 有一节书面登记——不允许静默豁免。测试名按 XCTest 运行时枚举核对（改名即红）。
import Foundation
import XCTest
@testable import PPassCore

enum MatrixCoverage {
    /// iOS 上不变量原样成立。
    case same([String])
    /// 机制在 iOS 上不同；变体文档必须有一节，测试钉住替代不变量。
    case variant([String])
    /// 两端实现都与矩阵不一致（已挂号）；变体文档必须有一节。
    case deviation([String])
    /// 行为在桌面；测的是手机侧那一半；变体文档必须有一节。
    case desktopSide([String])
    case retired

    var tests: [String] {
        switch self {
        case let .same(t), let .variant(t), let .deviation(t), let .desktopSide(t): return t
        case .retired: return []
        }
    }

    var needsDocSection: Bool {
        switch self {
        case .variant, .deviation, .desktopSide: return true
        case .same, .retired: return false
        }
    }
}

enum MatrixRegistry {
    static let entries: [String: MatrixCoverage] = [
        // O：order 与三层模型
        "O-01": .variant(["FlowEngineIOSTests/testDiscoveryOnlyMovesForwardAlongTheSourceOrder", "FlowEngineTests/testAReconcileScanCommitMovesSAndLeavesGToNewPhotos", "OrderStoreTests/testAFailureInsideTheWriteRollsBackStateAndCursorTogether"]),
        "O-02": .retired,
        "O-03": .variant(["FlowEngineIOSTests/testAChangedLibraryIdentityResetsTheCursor", "FlowEngineIOSTests/testAnExpiredDiscoveryCursorRescansAndConvergesWithoutDuplicates", "DeliveryPortTests/testTheWireTupleIsTheOrderIdAndATerminalOfferReplyConfirmsWithoutWaiting"]),
        "O-04": .same(["CaseMatrixTests/testO04_anEditedConfirmedPhotoIsSentAgainOnANewRowAndTheOldRowStaysConfirmed"]),
        "O-05": .same(["CaseMatrixTests/testO05_aTodoPhotoDeletedFromTheLibraryIsSettledAsSourceMissingAndNeverRetried"]),
        "O-06": .same(["CaseMatrixTests/testO06_cancelledPhotosAreNeverPickedUpByLaterReconcileRounds", "FlowEngineTests/testCancelSkipsExactlyThePhotosShownInTheDialog"]),
        "O-07": .same(["OrderStoreTests/testAFailureInsideTheWriteRollsBackStateAndCursorTogether", "OrderStoreTests/testTransitionIsCompareAndSetAndWritesEverythingInOneStep"]),
        "O-08": .same(["FlowEngineTests/testAConfirmedPhotoMissingOnTheDesktopIsReuploadedOnANewRow"]),
        "O-09": .same(["FlowEngineTests/testAFailingPhotoIsRetriedOnceOnTheSpotAndOnceByReconciliation"]),
        "O-10": .same(["FlowEngineTests/testTheTodoCountIsExactAndEachPhotoCountedOnce"]),
        "O-11": .same(["FlowEngineIOSTests/testADesktopMissingPhotoWhoseOriginalIsGoneIsRecordedOnceAndNotReuploaded"]),
        "O-12": .same(["FlowEngineTests/testCommittingAnExistingOrderNeverMovesGPastANewPhoto"]),
        "O-13": .same(["FlowEngineTests/testALegacyOrderWhoseImportedHashNoLongerMatchesIsReplacedByANewRow", "FlowEngineTests/testAnOldVersionLeftTransferringIsDroppedAndTheNewVersionGetsANewRow"]),
        "O-14": .same(["CaseMatrixTests/testO14_removingAnAlbumFromTheScopeWritesNoOrderStateAndDropsItsPhotosFromTheCount"]),
        // D：发现与计数
        "D-01": .same(["FlowEngineTests/testPickOrderIsLegacyThenScanThenNewThenReuploadsAndRetries"]),
        "D-02": .same(["CaseMatrixTests/testD02_triggersWhileRunningCoalesceIntoTheOneLoop"]),
        "D-03": .same(["CaseMatrixTests/testD03_aPhotoTakenDuringTheLoopIsSentInTheSameLoopUnderOneLease"]),
        "D-04": .same(["FlowEngineTests/testAFreshInstallScansTheExistingLibraryByIdAndStartsGAtTheNewest", "FlowEngineIOSTests/testAnExpiredDiscoveryCursorRescansAndConvergesWithoutDuplicates"]),
        "D-05": .retired,
        "D-06": .retired,
        "D-07": .variant(["OrderStoreTests/testDiscoveryPositionIsOverwrittenAndKeepsLibraryIdentity", "FlowEngineIOSTests/testAChangedLibraryIdentityResetsTheCursor"]),
        "D-08": .same(["CaseMatrixTests/testD08_theEntryCountIsExactAndReadsNoFile"]),
        // R：读文件
        "R-01": .variant(["CaseMatrixTests/testR01_aNewPhotoIsImportedExactlyOnce", "FlowEngineIOSTests/testTheEntryNeverTriggersAnICloudDownload"]),
        "R-02": .variant(["CaseMatrixTests/testR01_aNewPhotoIsImportedExactlyOnce", "DeliveryPortTests/testTheWireTupleIsTheOrderIdAndATerminalOfferReplyConfirmsWithoutWaiting"]),
        "R-03": .deviation(["FlowEngineTests/testALegacyOrderWhoseImportedHashNoLongerMatchesIsReplacedByANewRow", "FlowEngineIOSTests/testALegacyOrderWhoseICloudOriginalCannotBeFetchedIsLeftAsItIs"]),
        "R-04": .variant(["FlowEngineIOSTests/testLosingTheNetworkDuringAnICloudDownloadCountsNothing", "FlowEngineTests/testAnImportIsReleasedWhenTheRoundIsCancelledBeforeItIsDelivered"]),
        "R-05": .same(["DeliveryPortTests/testASourceFaultWhileServingIsSourceMissing", "FlowEngineTests/testPeerPathAndSourceMissingOutcomesNeverCountAFailure"]),
        // C：传输循环、中断与失败
        "C-01": .variant(["FlowEngineTests/testPauseOnlyWhileRunningKeepsTheInFlightOrderAndResumeContinuesIt", "DeliveryPortTests/testCancellingADeliverySuspendsTheDesktopFetchInsteadOfCancellingIt", "DeliveryPortTests/testADesktopThatNeverAnswersFlowSuspendCannotHoldThePauseLongerThanTheBound", "EngineWithPortTests/testPauseSuspendsTheDesktopFetchAndResumeContinuesTheSameTuple"]),
        "C-02": .same(["FlowEngineIOSTests/testPauseSurvivesARestartAndTriggersDoNothing"]),
        "C-03": .same(["FlowEngineTests/testPauseOnlyWhileRunningKeepsTheInFlightOrderAndResumeContinuesIt", "EngineWithPortTests/testPauseSuspendsTheDesktopFetchAndResumeContinuesTheSameTuple"]),
        "C-04": .same(["FlowEngineIOSTests/testWifiOnlyOnCellularWaitsWithAConstraintWake", "FlowEngineTests/testTheCountComesBeforeTheConditions"]),
        "C-05": .variant(["FlowEngineIOSTests/testAnExpiredLeaseStopsTheLoopAndWaits", "FlowEngineTests/testLosingTheNetworkStopsTheInFlightItemAsAPathFailure", "FlowEngineIOSTests/testANetworkChangeToCellularStopsTheRunningLoop"]),
        "C-06": .variant(["CaseMatrixTests/testD03_aPhotoTakenDuringTheLoopIsSentInTheSameLoopUnderOneLease", "DeliveryPortTests/testOnePushSubscriptionServesAWholeRoundAndTheFirstOfferWaitsForIt"]),
        "C-07": .same(["FlowEngineIOSTests/testTheLeaseIsRecheckedBeforeEveryItem"]),
        "C-08": .variant(["FlowEngineTests/testARefusedLeaseWaitsAndTheNextTriggerSimplyTriesAgain", "FlowEngineIOSTests/testEveryWaitReasonRegistersTheRightWake"]),
        "C-09": .same(["FlowEngineTests/testAFailingPhotoIsRetriedOnceOnTheSpotAndOnceByReconciliation", "FlowEngineTests/testAnImportThatThrowsTwiceCountsOneFailureAndMovesOn"]),
        "C-10": .same(["DeliveryPortTests/testConnectedButNoNewFileBytesIsAPathFailureAndDisconnects", "DeliveryPortTests/testBytesThatKeepMovingAreNeverMistakenForAStall"]),
        "C-11": .same(["DeliveryPortTests/testNobodyConnectedAsksTheDesktopAndKeepsWaitingWhileItSaysActive"]),
        "C-12": .same(["FlowEngineTests/testPeerPathAndSourceMissingOutcomesNeverCountAFailure", "DeliveryPortTests/testDesktopCodesMapToTheContract", "DeliveryPortTests/testAnOfferRefusedForSpaceIsAPeerFailure"]),
        "C-13": .variant(["FlowEngineTests/testLosingTheNetworkStopsTheInFlightItemAsAPathFailure"]),
        "C-14": .same(["FlowEngineIOSTests/testOneOutageSchedulesOneLadderAndASuccessResetsIt"]),
        "C-15": .same(["CaseMatrixTests/testC15_pauseIsIgnoredWhileWaiting", "FlowEngineTests/testPauseOnlyWhileRunningKeepsTheInFlightOrderAndResumeContinuesIt"]),
        "C-16": .same(["FlowEngineIOSTests/testTheWaitReasonSurvivesARestart"]),
        // H：桌面健康与半截
        "H-01": .same(["FlowEngineTests/testAnUnhealthyDesktopKeepsTheLoopWaitingWithoutTheLease"]),
        "H-02": .same(["DeliveryPortTests/testHelloHealthIsParsedAndAbsentMeansHealthy"]),
        "H-03": .desktopSide(["DeliveryPortTests/testTheOfferCarriesTheItemSizeAndMetadata", "DeliveryPortTests/testAnOfferRefusedForSpaceIsAPeerFailure"]),
        "H-04": .desktopSide(["DeliveryPortTests/testAnUnwritableLibraryOnAFullDiskReadsAsStorageFull", "DeliveryPortTests/testTheCriticallyLowLineMatchesTheDaemonSpaceReserve"]),
        "H-05": .desktopSide(["EngineWithPortTests/testPauseSuspendsTheDesktopFetchAndResumeContinuesTheSameTuple", "CaseMatrixTests/testP01_changingDesktopsDropsOldProgressButKeepsIntent"]),
        // E：完成凭据
        "E-01": .same(["DeliveryPortTests/testAMismatchedReceiptIsNeverAccepted", "FlowEngineTests/testAfterACleanRoundNothingIsLeftAndTheRoundCountedItsPhotos"]),
        "E-02": .same(["CaseMatrixTests/testE02_aConfirmedPhotoStaysConfirmedAfterItsAlbumLeavesTheScope"]),
        "E-03": .same(["CaseMatrixTests/testE03_cancelRemainingNeverTouchesConfirmedPhotos", "OrderStoreTests/testCancelRemainingWritesSkipListAndSkipsOpenOrdersButNotSettledOnes"]),
        // X：暂停、取消、恢复与改范围
        "X-01": .same(["FlowEngineTests/testCancelSkipsExactlyThePhotosShownInTheDialog", "EngineWithPortTests/testCancelRemainingDiscardsTheDesktopPartial"]),
        "X-02": .same(["OrderStoreTests/testCancelRemainingIsOneTransaction"]),
        "X-03": .same(["CaseMatrixTests/testO06_cancelledPhotosAreNeverPickedUpByLaterReconcileRounds", "FlowEngineTests/testCancelSkipsExactlyThePhotosShownInTheDialog"]),
        "X-04": .same(["CaseMatrixTests/testO14_removingAnAlbumFromTheScopeWritesNoOrderStateAndDropsItsPhotosFromTheCount", "FlowEngineTests/testAnInFlightOrderWhoseAlbumLeftTheScopeIsNotResumed"]),
        "X-05": .same(["EngineWithPortTests/testPauseSuspendsTheDesktopFetchAndResumeContinuesTheSameTuple", "FlowEngineTests/testPauseOnlyWhileRunningKeepsTheInFlightOrderAndResumeContinuesIt"]),
        "X-06": .retired,
        "X-07": .same(["CaseMatrixTests/testX07_aPausedPhotoDeletedBeforeContinueIsSettledAsSourceMissing"]),
        "X-08": .same(["FlowEngineTests/testCancelSkipsExactlyThePhotosShownInTheDialog"]),
        "X-09": .same(["FlowEngineTests/testWhilePausedOnlyIntentChangesAndResumingPicksUpRestoredPhotosAndANewAlbum", "FlowEngineTests/testRestoreKeepsWorkingWhenTheMediaSourceRepeatsARow"]),
        "X-10": .variant(["FlowEngineTests/testCancelWorksOnlyWhilePausedOrWaitingAndLeavesTheEngineIdle"]),
        // P：换 Desktop
        "P-01": .variant(["CaseMatrixTests/testP01_changingDesktopsDropsOldProgressButKeepsIntent", "OrderStoreTests/testChangingDesktopsClearsFactsKeepsSkipListAndLiftsIdFloor", "OrderStoreTests/testPairingANewDesktopDoesNotInheritTheOldDesktopsConfirmedCount", "OrderStoreTests/testRepairingTheSameDesktopKeepsConfirmedOrders", "DisconnectManifestTests/testDisconnectAppliesEveryRow"]),
        "P-02": .same(["CaseMatrixTests/testP02_aReceiptFromTheOldPairingNeverConfirms"]),
        // I：仅 iOS（#311 D4 / F3）
        "I-01": .same(["FlowEngineIOSTests/testANewPhotoWhoseICloudOriginalCannotBeFetchedWaitsWithoutCountingAFailure"]),
        "I-02": .same(["FlowEngineIOSTests/testALegacyOrderWhoseICloudOriginalCannotBeFetchedIsLeftAsItIs"]),
        "I-03": .same(["FlowEngineIOSTests/testAnOriginalThatIsGenuinelyUnavailableCountsAsAFailure"]),
        "I-04": .same(["FlowEngineIOSTests/testTheEntryNeverTriggersAnICloudDownload", "CaseMatrixTests/testD08_theEntryCountIsExactAndReadsNoFile"]),
        "I-05": .same(["FlowEngineIOSTests/testLosingTheNetworkDuringAnICloudDownloadCountsNothing"]),
        "I-06": .same(["FlowEngineIOSTests/testAnExpiredDiscoveryCursorRescansAndConvergesWithoutDuplicates"]),
        "I-07": .same(["FlowEngineIOSTests/testAnExpiredCursorWhileCountingGivesAnExactCountWithoutTouchingG"]),
        "I-09": .same(["FlowEngineIOSTests/testPhoneStorageFullWaitsWithoutCountingAnyFailure", "FlowEngineIOSTests/testPhoneStorageFullLeavesALegacyOrderAsItIs"]),
        "I-10": .same(["FlowEngineIOSTests/testAMisplacedCursorIsCaughtByTheNextReconcileRound", "FlowEngineIOSTests/testAnImpreciseCursorWithNothingMissingCostsNoLease"]),
        "I-08": .same(["FlowEngineIOSTests/testMediaIdsAreComparedByBytesNotByUnicodeEquivalence", "OrderStoreTests/testSQLiteOrderMatchesMediaOrder"]),
    ]
}

/// 矩阵与变体文档的解析（只认表格行首的 ID 与三级标题里的 ID，不做语义解析）。
enum MatrixDocs {
    static let dir = "docs/design/2026-08-29-arch01-backup-core"

    static func read(_ name: String) throws -> String {
        try String(contentsOf: RepoFixtures.repoRoot().appendingPathComponent("\(dir)/\(name)"), encoding: .utf8)
    }

    /// 表格行 `| X-NN | Given | …`：ID → 是否已废弃（Given 列以「已废弃」开头）。
    static func matrixRows(_ text: String) -> [String: Bool] {
        var out: [String: Bool] = [:]
        let pattern = try! NSRegularExpression(pattern: #"^\| ([A-Z]-\d{2}) \| ([^|]*)\|"#, options: .anchorsMatchLines)
        for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let id = String(text[Range(m.range(at: 1), in: text)!])
            let given = text[Range(m.range(at: 2), in: text)!].trimmingCharacters(in: .whitespaces)
            out[id] = given.hasPrefix("已废弃") || given.hasPrefix("Retired")
        }
        return out
    }

    /// 变体文档里 `### X-NN｜…` 的 ID。
    static func sectionIds(_ text: String) -> Set<String> {
        let pattern = try! NSRegularExpression(pattern: #"^### ([A-Z]-\d{2})"#, options: .anchorsMatchLines)
        return Set(pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { String(text[Range($0.range(at: 1), in: text)!]) })
    }

    /// 文档正文里引用的测试（`SomeTests.testName`）。
    static func citedTests(_ text: String) -> Set<String> {
        let pattern = try! NSRegularExpression(pattern: #"`([A-Za-z]+Tests)\.(test\w+)`"#)
        return Set(pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            "\(text[Range($0.range(at: 1), in: text)!])/\(text[Range($0.range(at: 2), in: text)!])"
        })
    }
}

final class CaseMatrixCoverageTests: XCTestCase {

    /// 运行时枚举所有测试类里真实存在的测试方法（"Class/testName"）。
    static var existingTests: Set<String> {
        let classes: [XCTestCase.Type] = [
            FlowEngineTests.self, FlowEngineIOSTests.self, CaseMatrixTests.self, DeliveryPortTests.self, EngineWithPortTests.self,
            OrderStoreTests.self, FlowControlStoreTests.self, PrefsTests.self, DisconnectManifestTests.self, StorageRootTests.self,
        ]
        var out = Set<String>()
        for cls in classes {
            for test in cls.defaultTestSuite.tests {
                // "-[PPassCoreTests.FlowEngineTests testFoo]"
                let name = test.name.trimmingCharacters(in: CharacterSet(charactersIn: "-[]"))
                let parts = name.split(separator: " ")
                guard parts.count == 2, let cls = parts[0].split(separator: ".").last else { continue }
                out.insert("\(cls)/\(parts[1])")
            }
        }
        return out
    }

    func testEveryMatrixRowIsCoveredOrRegistered() throws {
        let zh = MatrixDocs.matrixRows(try MatrixDocs.read("04-case-matrix.zh-CN.md"))
        XCTAssertEqual(zh.count, 73, "63 行 ARCH-01 + 10 行仅 iOS")
        XCTAssertEqual(Set(zh.keys), Set(MatrixRegistry.entries.keys), "矩阵与注册表的 ID 集合必须全等（新增行没登记 / 注册表有矩阵没有的 ID）")
        for (id, retired) in zh {
            guard let coverage = MatrixRegistry.entries[id] else { continue }
            if case .retired = coverage {
                XCTAssertTrue(retired, "\(id)：注册表说已废弃，矩阵没有")
            } else {
                XCTAssertFalse(retired, "\(id)：矩阵已废弃，注册表还在覆盖")
                XCTAssertFalse(coverage.tests.isEmpty, "\(id)：没有任何测试")
            }
        }
    }

    /// 中英两份矩阵的 ID 与「已废弃」标记一致。
    func testTheEnglishMatrixHasTheSameRows() throws {
        let zh = MatrixDocs.matrixRows(try MatrixDocs.read("04-case-matrix.zh-CN.md"))
        let en = MatrixDocs.matrixRows(try MatrixDocs.read("04-case-matrix.md"))
        XCTAssertEqual(zh, en)
    }

    /// 注册表引用的每一个测试都真实存在（运行时枚举，不比字符串）。
    func testEveryRegisteredTestExists() {
        let existing = Self.existingTests
        XCTAssertGreaterThan(existing.count, 100)
        for (id, coverage) in MatrixRegistry.entries.sorted(by: { $0.key < $1.key }) {
            for test in coverage.tests {
                XCTAssertTrue(existing.contains(test), "\(id)：引用的测试不存在：\(test)")
            }
        }
    }

    /// 变体 / 偏离 / 桌面侧的每一行在变体文档里有一节；文档里的小节都对应矩阵里存在、且登记为需要小节的 ID；
    /// 文档里点名的测试都真实存在。
    func testTheVariantRegisterMatchesTheRegistry() throws {
        let doc = try MatrixDocs.read("06-ios-variants.zh-CN.md")
        let sections = MatrixDocs.sectionIds(doc)
        let needed = Set(MatrixRegistry.entries.filter { $0.value.needsDocSection }.keys)
        XCTAssertEqual(sections, needed, "变体文档的小节与注册表里需要书面登记的 ID 必须全等")
        let existing = Self.existingTests
        for test in MatrixDocs.citedTests(doc) {
            XCTAssertTrue(existing.contains(test), "变体文档点名的测试不存在：\(test)")
        }
        let counts = Dictionary(grouping: MatrixRegistry.entries.values) { c -> String in
            switch c {
            case .same: return "同语义"
            case .variant: return "iOS 变体"
            case .deviation: return "实现偏离矩阵"
            case .desktopSide: return "桌面侧条目"
            case .retired: return "已废弃"
            }
        }.mapValues(\.count)
        print("case matrix coverage: \(counts.sorted { $0.key < $1.key })")
    }
}
