import Foundation
import PPassCore
import UIKit

// App 与业务之间的端口（#315）。界面只认这几个 protocol；壳阶段由 FakeBackend 实现，
// 集成阶段换成 PPassCore（Flow 引擎、账本）/ PPassMedia（PhotoKit）/ 传输 XCFramework 的适配器。
// 形状对位 Android：时间线 = TimelineLoader.page + thumb.get；配对 = PairFlow 的 PairOutcome；
// 相册 = MediaScanner.Bucket；首页 = FlowProjection（见 Home/HomeProjection.swift）。

/// 时间线里的一项（对位 Android `AssetMeta`）。
struct TimelineItem: Identifiable, Equatable, Hashable {
    let id: String          // 内容哈希
    let takenAt: Date
    let isVideo: Bool
    let width: Int?
    let height: Int?
    let bytes: Int64?
    /// 是不是这台手机拍的（「仅本机 / 家人的」筛选）；nil = 不知道，只在「全部」里出现。
    let isMine: Bool?
}

struct TimelinePage: Equatable {
    let items: [TimelineItem]
    let nextCursor: String?
}

/// 时间线（电脑上照片库里的照片）。
protocol TimelineSource: AnyObject {
    func page(cursor: String?) async throws -> TimelinePage
    func thumbnail(_ item: TimelineItem, large: Bool) async throws -> UIImage
    /// 取原图到本地临时文件（保存到相册 / 分享 / 播放视频用）。
    func original(_ item: TimelineItem, progress: @escaping (Double) -> Void) async throws -> URL
}

/// 手机相册里的一个相册（对位 Android `MediaScanner.Bucket`）。
struct AlbumBucket: Identifiable, Equatable {
    let id: String
    /// nil = 系统没给名字（界面显示 bucket_unnamed）。
    let name: String?
    let count: Int
}

/// 手机相册：授权、相册列表、备份范围。
protocol MediaLibrary: AnyObject {
    func access() -> MediaAccess
    func requestAccess() async -> MediaAccess
    func albums() async throws -> [AlbumBucket]
    func cover(_ album: AlbumBucket, side: CGFloat) async -> UIImage?
    /// nil = 从未保存过范围（与空集不同：空集 = 一个都不备份）。
    func savedScope() -> Set<String>?
    /// 上次保存范围时已知的相册（新出现的相册标「新」、默认不勾）。
    func knownAlbums() -> Set<String>
    func saveScope(_ selected: Set<String>, known: Set<String>) async
}

enum PairingStatus: Equatable {
    case notPaired
    case paired(desktopName: String)
    /// 配对失效（电脑上删了这台设备 / 换了库）——出路是重新扫码。
    case lost(desktopName: String)
}

/// 配对结局（对位 Android `PairOutcome`）。
enum PairOutcome: Equatable {
    /// firstTime = 这台电脑以前没连过（要去选相册）。
    case joined(firstTime: Bool)
    /// 电脑那边说不（ownerSaidNo）或这次没完成（过期 / 电脑重启 / 版本太旧）。msgKey 是 diag 的说明。
    case refused(msgKey: String?, ownerSaidNo: Bool)
    case failed(reason: String)
}

protocol PairingService: AnyObject {
    func status() -> PairingStatus
    /// 配对时间（毫秒）；未配对 / 未知 = nil。
    func pairedAtMs() -> Int64?
    /// code 是二维码内容或手动粘贴的配对串（同一个字符串，`ppf://pair?...`）。
    func pair(code: String) async -> PairOutcome
    func cancel() async
    /// 本地断开（UX-06）：先尽力通知电脑撤销本机（5 秒、失败不阻塞），再按断开清单清本地。成功后状态变 `.notPaired`。
    func disconnect() async
}

/// 备份引擎：首页的全部事实 + 唯一的那个按钮。
protocol BackupEngine: AnyObject {
    func facts() -> FlowFacts
    /// 引擎视图或账目变化时回调（主线程）。
    func observe(_ onChange: @escaping () -> Void)
    /// 英雄区按钮：进行中 = 暂停，已暂停 = 继续（Android MOB-19：同一条路）。
    func pauseOrResume() async
    /// 前台追赶：打开 App / 回到前台 / 选完相册时叫醒一轮。
    func wake() async
    func retryFailed() async
    /// 「取消剩余 N 张」：点击那一刻的快照（N 与取消边界是同一个差集）。
    func remainingSnapshot() async -> RemainingSnapshot?
    func cancelRemaining(_ snapshot: RemainingSnapshot) async -> Int?
    /// 「已跳过的照片 · 点击恢复」。
    func restoreSkipped() async
    /// 源已删除那批的「知道了」。
    func acknowledgeMissingSource()
    /// 失败通知开关（本地通知；默认开）。
    func notifyOnFailure() -> Bool
    func setNotifyOnFailure(_ on: Bool)
    /// 「仅 Wi-Fi 时备份」（引擎 Conditions.wifiOnly 的唯一来源，默认开）。
    func wifiOnly() -> Bool
    func setWifiOnly(_ on: Bool)
    /// 「后台备份」：关 = 只在打开 App 时备份（Conditions.autoBackupEnabled）。
    func autoBackup() -> Bool
    func setAutoBackup(_ on: Bool)
    /// #343「iOS 不承诺什么」：首页常驻告示（PPassCore BackupPromise），文案 key 走 DiagText。
    func promise() -> [PromiseNotice]
}

/// 一次运行用的全部端口。
struct Backend {
    /// 诊断页如实显示：现在是演示数据还是真数据。
    let isDemo: Bool
    let timeline: TimelineSource
    let media: MediaLibrary
    let pairing: PairingService
    let engine: BackupEngine
}

/// 配对串的形状校验（对位 Android ScanScreen 的 `startsWith("ppf://pair")`）。手动输入与扫码是同一个字符串。
enum PairCode {
    static let prefix = "ppf://pair"

    static func normalized(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.hasPrefix(prefix) ? s : nil
    }
}
