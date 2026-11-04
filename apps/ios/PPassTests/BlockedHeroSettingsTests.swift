@testable import PPass
import XCTest

/// #1353：权限被收回后「自动备份已停止」状态卡的出口（对位 Android `BlockedHeroSettingsTest`）。
/// 开关开 + 权限部分 / 全拒 → 带「去设置」；开关开 + 全部 → 不出；开关关 → 不出。
final class BlockedHeroSettingsTests: XCTestCase {
    /// 反证：去掉 `access != .full` 或 `autoRule` 任一条件，对应断言红。
    func testSettingsButtonShowsOnlyWhenRuleOnAndAccessNotFull() {
        XCTAssertTrue(AppModel.blockedHeroOffersSettings(autoRule: true, access: .partial), "部分")
        XCTAssertTrue(AppModel.blockedHeroOffersSettings(autoRule: true, access: .none), "全拒")
        XCTAssertFalse(AppModel.blockedHeroOffersSettings(autoRule: true, access: .full), "全部：不出")
        XCTAssertFalse(AppModel.blockedHeroOffersSettings(autoRule: false, access: .partial), "开关关：不出")
        XCTAssertFalse(AppModel.blockedHeroOffersSettings(autoRule: false, access: .none), "开关关：不出")
    }

    /// 文案对齐 Android：按钮词条来自 Android strings.xml 的同步副本。
    func testButtonTitleIsTheSharedString() {
        XCTAssertEqual(L.s("auto_backup_blocked_action"), Bundle.main.localizedString(forKey: "auto_backup_blocked_action", value: nil, table: nil))
        XCTAssertNotEqual(L.s("auto_backup_blocked_action"), "auto_backup_blocked_action", "词条要在 Localizable 里")
    }
}
