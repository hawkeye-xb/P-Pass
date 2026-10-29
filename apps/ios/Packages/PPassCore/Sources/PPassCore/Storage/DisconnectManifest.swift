// 断开时「什么留什么清」的唯一落点（对位 Android `DisconnectStateManifest.kt`，MOB-95 #282）。
//
// - 存储根下每一样持久状态、每一个断开时要停的运行时生产者，都在 [DisconnectState] 里登记一行：处置 + 依据。
// - 断开只做一件事：[applyDisconnectManifest] 按清单逐行执行。不存在清单之外的断开动作。
// - 新增持久状态不登记会被门禁挡下（`unregisteredStatePaths`：真跑完全部 store 的往返之后遍历目录）。
//
// 与 Android 的差异：iOS 只有一个存储根（App 容器 Application Support 下的 `PPass/`），没有 files / shared_prefs / databases 三处；
// 旧文件有两样，都存着凭据，不能套 Android RETIRED 的「无人读、留着无妨」，所以登记成 CLEAR、启动时也删：
// #956 撤销的断开发件箱（`legacyUnpairOutbox`，旧电脑的 peerToken，[UnpairNotice.removeLegacyOutbox]）；
// #1107 之前的明文私钥（`legacyPlaintextIdentity`，[DeviceIdentity] 见到就按新设备处理）。
import Foundation

/// 路径相对哪个根（#1119）：原图缓存不在存储根里——视频在系统 Caches，照片原图与取回临时仓库在 tmp。
public enum DisconnectBase: Equatable, Sendable {
    case storageRoot
    case caches
    case tmp
}

/// 存储根之外的两个根。生产用 [system]；测试注入临时目录——**不传就不碰这两个根**（包测试跑在开发机上，不许误删真缓存）。
public struct DisconnectExternalRoots: Sendable {
    public var caches: URL
    public var tmp: URL

    public init(caches: URL, tmp: URL) {
        self.caches = caches
        self.tmp = tmp
    }

    public static var system: DisconnectExternalRoots {
        DisconnectExternalRoots(caches: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0], tmp: FileManager.default.temporaryDirectory)
    }
}

/// 存储根之外、App 自己落盘的目录名（时间线与清单共用这一份，不各写各的字面量）。
public enum OriginalCachePaths {
    /// `Caches/ppass-videos/`：时间线视频原图（含 `.part`）。
    public static let videosDirName = "ppass-videos"
    /// `tmp/ppass-share/`：照片原图即用即清。
    public static let shareDirName = "ppass-share"
    /// `tmp/ppass-blobstore/`：取电脑原图时 iroh-blobs 的临时仓库。
    public static let fetchScratchDirName = "ppass-blobstore"
    /// `tmp/ppass-originals/`：备份导入器的临时目录（手机自己的照片，不是电脑的原图缓存）。
    public static let importScratchDirName = "ppass-originals"
}

public enum DisconnectDisposition: Equatable, Sendable {
    /// 不碰。
    case keep
    /// 删掉。
    case clear
    /// 文件留着，改写其中一部分（逐项实现见 [applyDisconnectManifest]）。
    case reset
    /// 运行时生产者：停掉。
    case stop
}

/// 依据前缀：没有卡定过语义，现状保留、待拍板（与 Android 同一批行同一个结论）。
public let undecidedBasis = "待拍板"

/// 断开时的状态清单。**声明顺序就是执行顺序**（配对凭据最先作废）。
/// [path] 相对存储根；`<id>` 匹配一段任意名字（daemonNodeId）。一行同时覆盖以 `.` / `-` 接续的伴生文件
/// （`backup-orders.db-wal`、`x.json.tmp`……）与该路径下的子项。`path == nil` 的是运行时生产者。
public enum DisconnectState: CaseIterable, Sendable {
    case pairing
    case legacyUnpairOutbox
    case flowRuntime
    case autoBackupPrefs
    case scheduledWakes
    case backgroundWakePlan
    case mediaChangeObserver
    case originalVideoCache
    case originalShareTemp
    case fetchScratch
    case thumbnailMemoryCache
    case importScratch
    case identity
    case legacyPlaintextIdentity
    case onboardedDesktops
    case backupScope
    case backupScopeUnpaired
    case backupSettings
    case orderDB
    case nativeBlobStore
    case flowControl
    case notifyOnFailurePrefs
    case onboardingNotificationAsk
    case definitiveNotices
    case sentinel
    case savedToGallery

    /// 路径相对哪个根。运行时行没有路径，按存储根算。
    public var base: DisconnectBase {
        switch self {
        case .originalVideoCache: return .caches
        case .originalShareTemp, .fetchScratch, .importScratch: return .tmp
        default: return .storageRoot
        }
    }

    public var path: String? {
        switch self {
        case .pairing: return "pairing.json"
        case .legacyUnpairOutbox: return "pending_unpair.json"
        case .backgroundWakePlan: return PlannedWakeScheduler.fileName
        case .flowRuntime, .scheduledWakes, .mediaChangeObserver, .thumbnailMemoryCache: return nil
        case .originalVideoCache: return OriginalCachePaths.videosDirName
        case .originalShareTemp: return OriginalCachePaths.shareDirName
        case .fetchScratch: return OriginalCachePaths.fetchScratchDirName
        case .importScratch: return OriginalCachePaths.importScratchDirName
        case .autoBackupPrefs: return AutoBackupPrefs.fileName
        case .identity: return DeviceIdentity.markerFileName
        case .legacyPlaintextIdentity: return DeviceIdentity.legacyPlaintextFileName
        case .onboardedDesktops: return OnboardedDesktopsStore.fileName
        case .backupScope: return "\(BackupScopeStore.legacyName)-<id>.json"
        case .backupScopeUnpaired: return "\(BackupScopeStore.legacyName).json"
        case .backupSettings: return BackupSettings.fileName
        case .orderDB: return SQLiteOrderStore.fileName
        case .nativeBlobStore: return "iroh-blobs-provider"
        case .flowControl: return FlowControlStore.fileName
        case .notifyOnFailurePrefs: return NotifyOnFailurePrefs.fileName
        case .onboardingNotificationAsk: return "onboarding_notification_ask.json"
        case .definitiveNotices: return DefinitiveNoticeStore.fileName
        case .sentinel: return SentinelStore.fileName
        case .savedToGallery: return SavedToGalleryStore.fileName
        }
    }

    public var disposition: DisconnectDisposition {
        switch self {
        case .pairing, .legacyUnpairOutbox, .backgroundWakePlan, .legacyPlaintextIdentity,
             .originalVideoCache, .originalShareTemp, .fetchScratch, .savedToGallery: return .clear
        case .flowRuntime, .scheduledWakes, .mediaChangeObserver, .thumbnailMemoryCache: return .stop
        case .autoBackupPrefs: return .reset
        default: return .keep
        }
    }

    /// 依据（卡号）。与 Android 同一行的依据一致；iOS 特有的写明。
    public var basis: String {
        switch self {
        case .pairing: return "UX-06/UX-06b：本地单方断开，令牌作废（#282）"
        case .legacyUnpairOutbox: return "#956 撤销（2026-10-22 裁决：主动断开只尽力通知一次）：老版本的断开发件箱，存着旧电脑的 peerToken、已无读写者；断开清掉，启动也删一次"
        case .flowRuntime: return "#264/MOB-91：同一 NodeId 重连不许复活旧的运行时；#974：provider 撤销（掐在飞传输 + revoke + 清允许对端），对位 Android clearFlowRuntime"
        case .originalVideoCache: return "#1119：断开后不许留这台电脑的原图；视频原图缓存（含 .part）整目录清掉，对位 Android cacheDir/video-*.mp4"
        case .originalShareTemp: return "#1119：照片原图即用即清的目录，断开时清掉可能的残留，对位 Android cacheDir/share/"
        case .fetchScratch: return "#1119：取电脑原图时的 iroh-blobs 临时仓库，里面是取回的原图字节，断开清掉（待确认是否算「原图缓存」，见汇报）"
        case .thumbnailMemoryCache: return "#1119：时间线缩略图的内存缓存（NSCache），断开清空，对位 Android LruCache"
        case .importScratch: return "\(undecidedBasis)：备份导入器的临时目录，装的是手机自己的照片而非电脑的原图；引擎停止时自己收拾，断开不碰"
        case .autoBackupPrefs: return "MOB-93：停生产者（autoEnabled=false），留意图（userRequested）"
        case .backgroundWakePlan: return "MOB-93 的 iOS 对位（#340）：后台唤醒计划是生产者的一部分，断开清掉；挂着的系统请求由 scheduledWakes 撤"
        case .scheduledWakes: return "MOB-93 的 iOS 对位：BGTaskScheduler 登记的唤醒是生产者，断开撤掉"
        case .mediaChangeObserver: return "MOB-27/MOB-93 的 iOS 对位：PHPhotoLibrary 变更监听是生产者，断开停掉"
        case .identity: return "红线：密钥就是这台设备（#282）。私钥在钥匙串（首次解锁后、仅本设备，不进备份），本行是存储根里「本次安装」的标记：没有标记的私钥是卸载重装留下的，按新设备处理（DeviceIdentity）"
        case .legacyPlaintextIdentity: return "旧版本存在存储根的明文私钥：启动时见到就按新设备处理并删掉（DeviceIdentity）；断开也清，明文私钥不许留"
        case .onboardedDesktops: return "MOB-114（#455/#461）：「连过这台」必须活过断开；只增不减"
        case .backupScope: return "MOB-92（#266）：相册范围按桌面分，断开不清"
        case .backupScopeUnpaired: return "MOB-92（#266）：未配对时的全局范围，一次性认领的来源，断开不碰"
        case .backupSettings: return "#282 验收 4：Wi-Fi 设置仍保留"
        case .orderDB: return "#413/#415 裁决 6：连回同一台桌面 CONFIRMED 仍有效；换一台由 OrderStore.claimOwner 清"
        case .nativeBlobStore: return "MOB-91 / IOS-07：原生内容仓库断开只 revoke，仓库本身不动"
        case .flowControl: return "\(undecidedBasis)：暂停标志 / 等待原因（#413），Android 断开从来没碰过"
        case .notifyOnFailurePrefs: return "\(undecidedBasis)：设置页「需要处理时通知我」（#130），Android 断开从来没碰过"
        case .onboardingNotificationAsk: return "#1262 退役：onboarding 不再申请通知，「只问一次」的记录已无读写者；老版本留下的文件不含凭据，留着无妨（对位 Android RETIRED）"
        case .definitiveNotices: return "#130/#981：失败通知的去重状态（已为哪个配对代号发过、上次相册档位 / 后台刷新状态）；对位 Android definitive_notices.json（KEEP）——清掉会让下次评估把现状当基线重发"
        case .sentinel: return "\(undecidedBasis)：「3 天没连上电脑」哨兵（SENT-01），Android 断开从来没碰过"
        case .savedToGallery: return "#1152：「保存到相册」的去重记录（内容哈希 → 相册 localIdentifier），记着这台电脑的哪些照片存进过本机相册，断开清掉；原先在 UserDefaults（清不掉、进备份），现在是存储根里的文件（整个存储根不进备份）。iOS 独有（Android 的「已保存」是 MediaStore 里的现成条目，没有这份记录）"
        }
    }

    /// [rel]（相对存储根、以 `/` 分隔）是否属于这一行。
    public func matches(_ rel: String) -> Bool {
        guard let path else { return false }
        let pattern = "^" + path.components(separatedBy: "<id>").map(NSRegularExpression.escapedPattern(for:)).joined(separator: "[^/]+") + "([/.\\-].*)?$"
        return rel.range(of: pattern, options: .regularExpression) != nil
    }
}

/// 断开时要停的、不落盘的东西——App 层实现，测试里记账。
public protocol DisconnectRuntime {
    func stopFlowRuntime()
    func cancelScheduledWakes()
    func stopMediaChangeObserver()
    /// 时间线缩略图的内存缓存清空。
    func clearThumbnailMemoryCache()
}

/// 断开（UX-06）与「配对失效重新扫码」共用的清理：按 [DisconnectState] 逐行执行，不依赖桌面是否可达。
/// 某一行失败（清文件出错）不短路后面的行：运行时停止行（provider 撤销、唤醒、相册监听）必须照常执行，
/// 否则「配对文件删不掉」会连带让旧桌面还能拉原图（#974）。所有行跑完后抛出第一个错误，不吞。
///
/// [external]：存储根之外的 Caches / tmp（原图缓存，#1119）。生产传 `.system`；不传则这几行跳过并记一行日志。
public func applyDisconnectManifest(root: URL, runtime: DisconnectRuntime, logger: CoreLogger = NoopLogger(), manifest: [DisconnectState] = DisconnectState.allCases,
                                    external: DisconnectExternalRoots? = nil) throws {
    var firstError: Error?
    for state in manifest {
        do {
            switch state.disposition {
            case .keep:
                continue
            case .clear:
                switch state.base {
                case .storageRoot: try deleteMatching(root, state)
                case .caches, .tmp:
                    guard let external else { logger.log("disconnect: row \(state) skipped (no external roots given)"); continue }
                    try deleteMatching(state.base == .caches ? external.caches : external.tmp, state)
                }
            case .reset:
                switch state {
                case .autoBackupPrefs: try AutoBackupPrefs(directory: root, logger: logger).suspendForPairingChange()
                default: preconditionFailure("\(state): no RESET action defined")
                }
            case .stop:
                switch state {
                case .flowRuntime: runtime.stopFlowRuntime()
                case .scheduledWakes: runtime.cancelScheduledWakes()
                case .mediaChangeObserver: runtime.stopMediaChangeObserver()
                case .thumbnailMemoryCache: runtime.clearThumbnailMemoryCache()
                default: preconditionFailure("\(state): no STOP action defined")
                }
            }
        } catch {
            logger.log("disconnect: row \(state) failed: \(error)")
            if firstError == nil { firstError = error }
        }
    }
    if let firstError { throw firstError }
}

private func deleteMatching(_ root: URL, _ state: DisconnectState) throws {
    let fm = FileManager.default
    for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where state.matches(name) {
        try fm.removeItem(at: root.appendingPathComponent(name))
    }
}

/// 登记门禁的运行时一半：存储根下**不属于任何一行清单**的路径（已登记路径不再下钻；未登记的空目录也算）。
/// [external] 给了就再查 Caches / tmp 根下**以 `ppass-` 开头**的条目（不碰系统自己的东西）：没有登记的也列出来，
/// 以 `caches:` / `tmp:` 作前缀（#1119：新加的缓存目录不登记过不了门禁）。
public func unregisteredStatePaths(root: URL, manifest: [DisconnectState] = DisconnectState.allCases, external: DisconnectExternalRoots? = nil) -> [String] {
    var out: [String] = []
    let rootRows = manifest.filter { $0.base == .storageRoot }
    func walk(_ dir: URL, _ prefix: String) {
        let children = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        if children.isEmpty, !prefix.isEmpty { out.append(String(prefix.dropLast())) }
        for name in children {
            let rel = prefix + name
            if rootRows.contains(where: { $0.matches(rel) }) { continue }
            var isDir: ObjCBool = false
            let url = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                walk(url, rel + "/")
            } else {
                out.append(rel)
            }
        }
    }
    walk(root, "")
    if let external {
        for (base, label, dir) in [(DisconnectBase.caches, "caches:", external.caches), (.tmp, "tmp:", external.tmp)] {
            let rows = manifest.filter { $0.base == base }
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
            where name.hasPrefix("ppass-") && !rows.contains(where: { $0.matches(name) }) {
                out.append(label + name)
            }
        }
    }
    return out
}
