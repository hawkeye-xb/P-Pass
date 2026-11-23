// #1964：电脑端不再认这台手机、本地配对已被「被拒即清理」（#1119）删掉——这件事要在**下一次打开 App 时**说明一次
// （对位 Android `PairingRemovedNoticeStore`，#1219）。
//
// 清理多半发生在后台（投递、探测、周期任务），当时没有界面；系统通知又依赖通知权限。所以把「有一条待说明的移除」落盘，
// 界面在用户看到时弹一次，点「知道了」即清（一次性事件持久化后在前台确认，与系统的「账号已被移除」提示同一做法）。
//
// - 放在存储根顶层，断开清单里登记为 KEEP：它在清理**之后**写入，必须活过这次清理；
// - 重新配对成功后就不再说明（界面只在没有配对时弹，有配对时顺手清掉）；
// - 纯文件 IO，包测试能真跑往返。
import Foundation

public struct PairingRemovedNoticeStore: Sendable {
    public static let fileName = "pairing_removed_notice"

    private let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent(Self.fileName)
    }

    /// 记下：本地配对已被被拒即清理删掉，待说明。写盘失败抛出（不假装记下了）。
    public func record() throws {
        JSONFile.lock.lock(); defer { JSONFile.lock.unlock() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url, options: .atomic)
    }

    /// 有没有待说明的移除。
    public func pending() -> Bool {
        JSONFile.lock.lock(); defer { JSONFile.lock.unlock() }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// 用户看过了（或已经重新配对），不再说明。
    public func clear() {
        JSONFile.lock.lock(); defer { JSONFile.lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }
}
