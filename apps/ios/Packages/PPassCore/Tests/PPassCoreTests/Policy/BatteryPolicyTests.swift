// #980：电量低阈值与 Android 同口径（`isBatteryLow`：未插电且 ≤ 15%；与 WorkManager requiresBatteryNotLow 一致）。
import XCTest
@testable import PPassCore

final class BatteryPolicyTests: XCTestCase {
    func testThresholdIsFifteenPercent() {
        XCTAssertEqual(BatteryPolicy.lowThresholdPercent, 15)
    }

    /// 边界：14 低、15 低（≤ 不是 <）、16 不低。
    func testBoundaryAroundFifteenPercent() {
        XCTAssertTrue(BatteryPolicy.isLow(level: 0.14, unplugged: true))
        XCTAssertTrue(BatteryPolicy.isLow(level: 0.15, unplugged: true))
        XCTAssertFalse(BatteryPolicy.isLow(level: 0.16, unplugged: true))
    }

    /// 旧阈值 20% 下的 15–20% 区间不再算低（#980 的现象）。
    func testBetweenFifteenAndTwentyIsNotLow() {
        for pct in 16...20 { XCTAssertFalse(BatteryPolicy.isLow(level: Float(pct) / 100, unplugged: true), "\(pct)%") }
    }

    /// iOS 的 batteryLevel 是 Float：整数百分比换算成小数再乘回来不能因浮点误差越过边界。
    func testEveryIntegerPercentIsClassifiedExactly() {
        for pct in 0...100 {
            XCTAssertEqual(BatteryPolicy.isLow(level: Float(pct) / 100, unplugged: true), pct <= 15, "\(pct)%")
        }
    }

    func testPluggedInIsNeverLow() {
        XCTAssertFalse(BatteryPolicy.isLow(level: 0.01, unplugged: false))
        XCTAssertFalse(BatteryPolicy.isLow(level: 0.15, unplugged: false))
    }

    /// 读不到电量（UIDevice 返回 -1，模拟器 / 未开监听）不算低。
    func testUnreadableLevelIsNotLow() {
        XCTAssertFalse(BatteryPolicy.isLow(level: -1, unplugged: true))
    }
}
