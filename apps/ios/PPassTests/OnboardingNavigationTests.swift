import XCTest
@testable import PPass

/// 手动输入配对串的「返回」：从哪儿进来就回哪儿（Android ScanScreen `leaveManual`）。
final class OnboardingNavigationTests: XCTestCase {
    func testManualFromScanGoesBackToScan() {
        XCTAssertEqual(OnboardingFlow.manualBackTarget(fromScan: true), .scan)
    }

    func testManualFromWelcomeGoesBackToWelcome() {
        XCTAssertEqual(OnboardingFlow.manualBackTarget(fromScan: false), .welcome)
    }
}
