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
    /// 「最近项目」（整个图库）：iOS 上相机拍的照片只在这里，首次选范围默认勾上它（#1263，对位 Android 相机相册）。
    var isCameraAlbum = false
}

/// 手机相册：授权、相册列表、备份范围。
protocol MediaLibrary: AnyObject {
    func access() -> MediaAccess
    func requestAccess() async -> MediaAccess
    func albums() async throws -> [AlbumBucket]
    func cover(_ album: AlbumBucket, side: CGFloat) async -> UIImage?
    /// nil = 从未保存过范围（与空集不同：空集 = 一个都不备份）。读盘失败抛出，不当成「从未保存」（#971）。
    func savedScope() throws -> Set<String>?
    /// 时间档（#1263）；nil = 从未保存过范围。
    func savedSince() throws -> BackupSince?
    /// 上次保存范围时已知的相册（新出现的相册标「新」、默认不勾）。
    func knownAlbums() -> Set<String>
    /// 当前系统里实际存在的相册 id；没有完整授权（读不到相册）= nil。不弹授权。
    func existingAlbumIds() async -> Set<String>?
    /// 写盘失败抛出（#971）：调用方不许当成已保存。
    func saveScope(_ selected: Set<String>, known: Set<String>, since: BackupSince) async throws
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
    /// settingSaveFailed = 配对成功，但换新电脑时清旧的后台备份意图没写下来（#1039）：不拦配对，提示用户，
    /// 首次选完范围时会再写一次「关」（#1263）。
    case joined(firstTime: Bool, settingSaveFailed: Bool = false)
    /// 电脑上点了「拒绝」（ownerSaidNo）或这次没完成（配对码无效 / 过期 / 电脑重启……，10-29 文案 B6）。
    /// note 是本端挑的原因行（自带操作，B5）；nil 或 `.denied` = 只有标题。
    case refused(note: PairNote?, ownerSaidNo: Bool)
    /// #1069：版本不兼容，要先更新 [OutdatedSide] 那一端的 P-Pass（不是电脑主人拒绝的）。
    case needsUpdate(OutdatedSide)
    /// 没能完成配对。#1264：diagnostic 只进日志（异常、关闭码、RPC 原因——不上屏，tokens.json rules 第 10 条）；
    /// kind 决定失败页（10-29 文案 B7：扫到的不是配对码单独成页，不套「无法连接电脑」）。
    case failed(diagnostic: String, kind: PairFailure = .unreachable)
}

/// 配对没能完成的几种页面（对位 Android `PairFailure`；iOS 没有「码里缺地址」那一支）。
enum PairFailure: Equatable {
    /// 连不上电脑（以及其他半路出错）：「无法连接电脑」+ 联网建议。
    case unreachable
    /// 扫到 / 粘贴的不是 P-Pass 配对码：只有标题。
    case notACode
    /// 电脑已经允许了，配对信息没能写进手机：「加入失败」+ 存储空间（10-29 文案）。
    case saveFailed
}

/// 配对页的补充说明：本端按判决 / `reason` 挑，文字是本机文案（#1072 / #1073：线上不再带文案 key）。
enum PairNote: Equatable, CaseIterable {
    case tokenInvalid, denied, expired, desktopRestarted, generic
    /// #1264：电脑在握手时就拒了这台手机（未配对关闭码）：二维码已过期 / 已关掉 / 已被用掉。刷新二维码重扫。
    case qrExpired
    /// #1118：验证码对不上（`pair_code_wrong` / `failed`），这次申请作废。
    case codeWrong
    /// #1118：电脑没能证明它用的是同一个验证码（`confirm_b` 验不过），没有保存配对。
    case desktopProofFailed

    /// 与 Android 同一套 key（strings.xml → Localizable.strings）。电脑上点了「拒绝」没有原因行（10-29 文案 B5：标题已说清）。
    var key: String? {
        switch self {
        case .tokenInvalid: return "pair_refused_detail_token_invalid"
        case .denied: return nil
        case .expired: return "pair_refused_detail_expired"
        case .desktopRestarted: return "pair_refused_detail_restarted"
        case .generic: return "error_generic"
        case .codeWrong: return "pair_refused_detail_code_wrong"
        case .desktopProofFailed: return "pair_desktop_proof_failed"
        case .qrExpired: return "pair_qr_expired_body"
        }
    }

    var text: String? { key.map { L.s($0) } }

    /// 失败页标题（10-29 文案 B6 / C10，对位 Android `pairRefusalTitleRes`）：电脑上点了「拒绝」→「电脑拒绝了加入请求」；
    /// 二维码过期 →「二维码已过期」；其余（含没有说明）→「加入失败」。
    static func titleKey(_ note: PairNote?, ownerSaidNo: Bool) -> String {
        if ownerSaidNo { return "pair_refused_title" }
        return note == .qrExpired ? "pair_qr_expired_title" : "pair_lapsed_title"
    }

    /// 10-29 文案 B13：通用说明下面那行小字「错误代码：…」的代码 = 正文 key 去前缀（与桌面 `ui.err_code` 同一规则）。
    var errorCode: String? { self == .generic ? "generic" : nil }

    /// pair.request 被拒时的说明（#1072 §5）：配对码无效有专门一句，其余与不认识的 reason 一律通用提示。
    /// 版本不兼容不走这里（单独成判决）。
    init(rejection reason: DesktopReason) {
        self = reason == .registered(.pairTokenInvalid) ? .tokenInvalid : .generic
    }
}

/// 验证码页上的电脑：名字是电脑在 hello 里自报的（只作标签），标识由手机从二维码里的 NodeId 算出（与电脑二维码下方显示的一致）。
struct PairDesktopInfo: Equatable, Sendable {
    let name: String
    let fingerprint: String
}

/// #1118：提交成功（收到 `PairSubmitted`）之后才有：手机要显示给用户的验证码、要连的电脑，以及本机 NodeId（自动化客户端打 `PAIR_CODE=` 用）。
/// 扫码后不再问「要连接这台电脑吗？」：扫码就是连接的意图；换码冒充由验证码挡住（码只在手机上，用户输进自己的电脑）。
struct PairCodeShown: Equatable, Sendable {
    let code: String
    let desktop: PairDesktopInfo
    let phoneNode: String
}

/// 验证码要显示了。
typealias PairCodeSink = @Sendable (PairCodeShown) async -> Void

protocol PairingService: AnyObject {
    func status() -> PairingStatus
    /// 配对时间（毫秒）；未配对 / 未知 = nil。
    func pairedAtMs() -> Int64?
    /// code 是二维码内容或手动粘贴的配对串（同一个字符串，`ppf://pair?...`）。
    /// `onCode`：提交成功后才调，给验证码页（#1118）。扫码之后没有任何要用户点的步骤。
    func pair(code: String, onCode: @escaping PairCodeSink) async -> PairOutcome
    func cancel() async
    /// 本地断开（UX-06）：先尽力通知电脑撤销本机（5 秒、失败不阻塞），再按断开清单清本地。成功后状态变 `.notPaired`。
    func disconnect() async
    /// 只清本地、不通知电脑（#1119）：配对失效卡的「重新连接」——电脑本就不认这台手机，没有可通知的。
    func clearLocal() async
}

extension PairingService {
    /// 自动化 / 无界面调用：总是连接、不显示验证码。
    func pair(code: String) async -> PairOutcome { await pair(code: code, onCode: { _ in }) }
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
    /// #1272 挑几张传：这一批的进度 / 结果（没挑过 = nil）；登记一批并叫醒引擎。
    /// #1272 B：「自动备份」规则开关（没存过值时由后端按现状初始化过一次）。
    func autoRule() -> Bool
    func setAutoRule(_ on: Bool) throws
    /// 有限访问：把用户允许的照片按手选链路传一次，返回实际登记的张数。
    func sendAllowedPhotos() async -> Int
    func pickedSummary() -> PickedBatchSummary?
    func addPicked(_ items: [(fileName: String, mimeType: String, payload: PickedPayload)]) async
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
    /// 首次选范围页点「开始备份」：把「连过这台电脑」落盘（#1019 / #1263，对位 Android `finishOnboarding` 里的 markOnboarded，MOB-114）。
    /// 快速重连只认它；配对成功时不记，否则配完没走完首次设置就被杀，下次会跳过选范围。
    func finishOnboarding() throws
    /// 「仅 Wi-Fi 时备份」（引擎 Conditions.wifiOnly 的唯一来源，默认开）。
    func wifiOnly() -> Bool
    func setWifiOnly(_ on: Bool) throws
    /// 「后台备份」：关 = 只在打开 App 时备份（Conditions.autoBackupEnabled）。
    func autoBackup() -> Bool
    func setAutoBackup(_ on: Bool) throws
    /// 首页「开启后台备份」引导卡被用户关掉过（#1263）。
    func backgroundCardDismissed() -> Bool
    func dismissBackgroundCard() throws
    /// 系统「后台 App 刷新」的当前状态（设置页的后台告示据此判定）。
    func backgroundRefresh() -> BackgroundRefreshAvailability
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
