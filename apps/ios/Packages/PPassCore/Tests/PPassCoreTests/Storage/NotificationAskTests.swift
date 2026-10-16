// #975：通知授权——onboarding 只问一次（对位 Android OnboardingNotificationAskTest）+ 开关三态的纯函数。
import Foundation
import XCTest
@testable import PPassCore

final class NotificationAskTests: XCTestCase {

    // MARK: 只问一次

    func testNewInstallAsksOnceWhenNotDetermined() throws {
        let tmp = TempDir()
        let ask = OnboardingNotificationAsk(directory: tmp.url)
        ask.initIfAbsent(existingUser: false)
        XCTAssertTrue(ask.shouldAsk(authorization: .notDetermined))
    }

    func testMarkAskedBeforeRequestSurvivesRestart() throws {
        let tmp = TempDir()
        let ask = OnboardingNotificationAsk(directory: tmp.url)
        ask.initIfAbsent(existingUser: false)
        try ask.markAsked()
        // 重启 = 新实例：申请中途进程被杀，也不再问。
        XCTAssertFalse(OnboardingNotificationAsk(directory: tmp.url).shouldAsk(authorization: .notDetermined))
    }

    func testExistingUserIsNeverAsked() {
        let tmp = TempDir()
        let ask = OnboardingNotificationAsk(directory: tmp.url)
        ask.initIfAbsent(existingUser: true)
        XCTAssertFalse(ask.shouldAsk(authorization: .notDetermined))
        XCTAssertEqual(ask.load()?.skippedAsExistingUser, true)
    }

    func testInitIsIdempotentSoPairingLaterDoesNotMakeNewUserLookExisting() {
        let tmp = TempDir()
        let ask = OnboardingNotificationAsk(directory: tmp.url)
        ask.initIfAbsent(existingUser: false)
        ask.initIfAbsent(existingUser: true) // 配对成功后再进来
        XCTAssertTrue(ask.shouldAsk(authorization: .notDetermined))
    }

    func testMissingFileMeansDoNotAsk() {
        XCTAssertFalse(OnboardingNotificationAsk(directory: TempDir().url).shouldAsk(authorization: .notDetermined), "宁可少问，不许多问")
    }

    func testCorruptFileMeansAlreadyAsked() {
        let tmp = TempDir()
        tmp.write(OnboardingNotificationAsk.fileName, "{not json")
        XCTAssertFalse(OnboardingNotificationAsk(directory: tmp.url).shouldAsk(authorization: .notDetermined))
    }

    /// iOS 平台差异：系统只在 notDetermined 时才会弹框，其余两态问了也没有弹窗，不该问。
    func testOnlyNotDeterminedCanBeAsked() {
        let tmp = TempDir()
        let ask = OnboardingNotificationAsk(directory: tmp.url)
        ask.initIfAbsent(existingUser: false)
        XCTAssertFalse(ask.shouldAsk(authorization: .denied))
        XCTAssertFalse(ask.shouldAsk(authorization: .authorized))
    }

    func testResultSyncsToggleLikeAndroid() throws {
        let tmp = TempDir()
        let prefs = NotifyOnFailurePrefs(directory: tmp.url)
        let ask = OnboardingNotificationAsk(directory: tmp.url)
        try ask.onResult(granted: false, prefs: prefs)
        XCTAssertFalse(prefs.enabled())
        try ask.onResult(granted: true, prefs: prefs)
        XCTAssertTrue(prefs.enabled())
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
