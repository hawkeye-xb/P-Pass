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

/// 为什么取这一页（只进日志，#987）：区分「订阅信号触发的刷新」「兜底」「打开页面 / 下拉 / 重试」「翻页」。
enum TimelinePageReason: String {
    case open, pull, retry, more, signal, fallback, e2e
}

/// 时间线（电脑上照片库里的照片）。
protocol TimelineSource: AnyObject {
    func page(cursor: String?, reason: TimelinePageReason) async throws -> TimelinePage
    func thumbnail(_ item: TimelineItem, large: Bool) async throws -> UIImage
    /// 取原图到本地临时文件（保存到相册 / 分享 / 播放视频用）。
    /// 视频原图的本地缓存命中（字节数校验过）；没有 = nil。照片不缓存。
    func cachedOriginal(_ item: TimelineItem) -> URL?
    func original(_ item: TimelineItem, progress: @escaping (Double) -> Void) async throws -> URL
}

/// 照片页的实时更新通道（#963，对位 Android `TimelineSubscriptionHolder` 暴露给页面的那一面）。
/// 订阅属于 App 前台，不属于某个页面；页面只在出现时注册观察者，离开时丢掉，不创建 / 销毁连接。
enum TimelineLiveEvent: Equatable {
    /// 桌面说时间线变了：整页覆盖刷新。
    case invalidated
    /// 60 秒兜底：只追加，不动已加载内容。
    case fallbackTick
    case state(TimelineLiveState)
}

protocol TimelineLiveFeed: AnyObject {
    /// 注册观察者（主线程回调）。注册时立刻补发一次当前状态；返回的 token 释放 / 调 `remove` 即注销。
    @MainActor func observe(_ handler: @escaping @MainActor (TimelineLiveEvent) -> Void) -> UUID
    @MainActor func remove(_ token: UUID)
    /// 「实时更新已断开 · 重试」。
    @MainActor func retry()
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
    /// nil = 从未保存过范围（与空集不同：空集 = 一个都不备份）。读盘失败抛出，不当成「从未保存」（#971）。
    func savedScope() throws -> Set<String>?
    /// 上次保存范围时已知的相册（新出现的相册标「新」、默认不勾）。
    func knownAlbums() -> Set<String>
    /// 当前系统里实际存在的相册 id；没有完整授权（读不到相册）= nil。不弹授权。
    func existingAlbumIds() async -> Set<String>?
    /// 写盘失败抛出（#971）：调用方不许当成已保存。
    func saveScope(_ selected: Set<String>, known: Set<String>) async throws
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
    /// 命令的失败抛给调用方（#972）：「状态不允许」是返回值，「执行出错」是抛出，两者不混。
    func retryFailed() async throws
    /// 「取消剩余 N 张」：点击那一刻的快照（N 与取消边界是同一个差集）。
    func remainingSnapshot() async throws -> RemainingSnapshot
    /// nil = 当前状态不允许取消（已不在暂停 / 等待中）；抛出 = 执行出错（账本写失败等）。
    func cancelRemaining(_ snapshot: RemainingSnapshot) async throws -> Int?
    /// 「已跳过的照片 · 点击恢复」。
    func restoreSkipped() async throws
    /// 源已删除那批的「知道了」。
    func acknowledgeMissingSource()
    /// 失败通知开关（本地通知；默认开）。
    func notifyOnFailure() -> Bool
    /// 偏好写盘失败抛出（#971）。
    func setNotifyOnFailure(_ on: Bool) throws
    /// #975：系统通知授权的真实状态（开关显示 = 偏好 且 已授权）。
    func notificationAuthorization() async -> NotificationAuthorization
    /// 弹系统授权框（只在 notDetermined 时有界面），返回弹窗之后的状态。
    func requestNotificationAuthorization() async -> NotificationAuthorization
    /// denied 之后唯一的出路：跳系统设置里本 App 的通知页。
    @MainActor func openNotificationSettings()
    /// onboarding 完成页：该不该先问一次通知（页面据此显示用途说明）。
    func shouldAskNotificationAtOnboarding() async -> Bool
    /// 完成页点「好」：该问就问（先落盘「问过」），结果同步回开关。
    func askNotificationAtOnboarding() async
    /// 完成页点任一按钮：把「连过这台电脑」落盘（#1019，对位 Android `finishOnboarding` 里的 markOnboarded，MOB-114）。
    /// 快速重连只认它；配对成功时不记，否则配完没走完首次设置就被杀，下次会跳过选相册与后台备份的选择。
    func finishOnboarding() throws
    /// 「仅 Wi-Fi 时备份」（引擎 Conditions.wifiOnly 的唯一来源，默认开）。
    func wifiOnly() -> Bool
    func setWifiOnly(_ on: Bool) throws
    /// 「后台备份」：关 = 只在打开 App 时备份（Conditions.autoBackupEnabled）。
    func autoBackup() -> Bool
    func setAutoBackup(_ on: Bool) throws
    /// #343「iOS 不承诺什么」：首页常驻告示（PPassCore BackupPromise），文案 key 走 DiagText。
    func promise() -> [PromiseNotice]
}

/// 一次运行用的全部端口。
struct Backend {
    /// 诊断页如实显示：现在是演示数据还是真数据。
    let isDemo: Bool
    let timeline: TimelineSource
    let live: TimelineLiveFeed
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
