// 电量低判定（#980）。Android 对位：AndroidFlowRuntime.isBatteryLow——未插电且电量 ≤ 15%，
// 与 WorkManager `requiresBatteryNotLow` 同一口径。两端不分叉：阈值只在这里。
import Foundation

public enum BatteryPolicy {
    /// ≤ 该百分比算低（含边界）。
    public static let lowThresholdPercent = 15

    /// - level: UIDevice.batteryLevel（0...1；读不到 = -1）。
    /// - unplugged: 没在充电（插电时不算低）。
    public static func isLow(level: Float, unplugged: Bool) -> Bool {
        guard level >= 0, unplugged else { return false }
        // batteryLevel 是整数百分比 / 100 的 Float：四舍五入还原百分比，避免浮点误差越过边界。
        return Int((level * 100).rounded()) <= lowThresholdPercent
    }
}
