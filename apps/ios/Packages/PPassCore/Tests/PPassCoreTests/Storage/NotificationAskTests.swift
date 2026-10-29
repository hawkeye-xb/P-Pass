// #975 / #1262：通知开关的默认值（新装关、老用户保持）+ 开关三态的纯函数。
import Foundation
import XCTest
@testable import PPassCore

final class NotificationAskTests: XCTestCase {

    // MARK: 默认值（#1262）

    /// 新装：首次启动落盘「关」；之后配对、走完 onboarding 再调用也不变（幂等）。
    func testNewInstallDefaultsOffAndStaysOffAfterOnboarding() {
        let tmp = TempDir()
        NotifyOnFailurePrefs(directory: tmp.url).initIfAbsent(existingUser: false)
        XCTAssertFalse(NotifyOnFailurePrefs(directory: tmp.url).enabled())
        NotifyOnFailurePrefs(directory: tmp.url).initIfAbsent(existingUser: true) // 配对成功后的下一次启动
        XCTAssertFalse(NotifyOnFailurePrefs(directory: tmp.url).enabled(), "新用户不能因为后来配对了就被当成老用户打开")
    }

    /// 老用户升级、从没动过开关（没有文件）：保持升级前的默认「开」，不重置。
    /// 反证：initIfAbsent 改成一律写 false，这里红。
    func testUpgradedUserWithoutFileKeepsOldDefaultOn() {
        let tmp = TempDir()
        NotifyOnFailurePrefs(directory: tmp.url).initIfAbsent(existingUser: true)
        XCTAssertTrue(NotifyOnFailurePrefs(directory: tmp.url).enabled())
    }

    /// 老用户升级、以前写过开关（含旧 onboarding 申请结果写回的值）：原样保留，开着的不关、关着的不开。
    func testUpgradedUserKeepsSavedChoice() throws {
        for saved in [true, false] {
            let tmp = TempDir()
            try NotifyOnFailurePrefs(directory: tmp.url).setEnabled(saved)
            NotifyOnFailurePrefs(directory: tmp.url).initIfAbsent(existingUser: true)
            XCTAssertEqual(NotifyOnFailurePrefs(directory: tmp.url).enabled(), saved)
        }
    }

    // MARK: 开关三态

    func testToggleDisplayIsPreferenceAndAuthorized() {
        for (pref, auth, shown) in [
            (true, NotificationAuthorization.authorized, true),
            (true, .notDetermined, false), (true, .denied, false),
            (false, .authorized, false), (false, .notDetermined, false), (false, .denied, false),
        ] {
            XCTAssertEqual(NotifyToggle.displayValue(preference: pref, authorization: auth), shown, "\(pref) \(auth)")
        }
    }

    func testTurnOnActionPerAuthorization() {
        XCTAssertEqual(NotifyToggle.turnOnAction(authorization: .authorized), .enable)
        XCTAssertEqual(NotifyToggle.turnOnAction(authorization: .notDetermined), .requestAuthorization)
        XCTAssertEqual(NotifyToggle.turnOnAction(authorization: .denied), .openSystemSettings)
    }

    func testOnlyAuthorizedCanDeliver() {
        XCTAssertTrue(NotifyToggle.canDeliver(.authorized))
        XCTAssertFalse(NotifyToggle.canDeliver(.notDetermined))
        XCTAssertFalse(NotifyToggle.canDeliver(.denied))
    }
}
