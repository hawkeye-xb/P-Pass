// 断开时「什么留什么清」的唯一落点（对位 Android `DisconnectStateManifest.kt`，MOB-95 #282）。
//
// - 存储根下每一样持久状态、每一个断开时要停的运行时生产者，都在 [DisconnectState] 里登记一行：处置 + 依据。
// - 断开只做一件事：[applyDisconnectManifest] 按清单逐行执行。不存在清单之外的断开动作。
// - 新增持久状态不登记会被门禁挡下（`unregisteredStatePaths`：真跑完全部 store 的往返之后遍历目录）。
//
// 与 Android 的差异：iOS 只有一个存储根（App Group 容器里的 `PPass/`），没有 files / shared_prefs / databases 三处；
// 唯一的旧文件是 #956 撤销的断开发件箱（`legacyUnpairOutbox`）：它存着旧电脑的 peerToken，不能套 Android RETIRED 的「无人读、留着无妨」，
// 所以登记成 CLEAR，启动时也删一次（[UnpairNotice.removeLegacyOutbox]）。
import Foundation

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
    case identity
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

    public var path: String? {
        switch self {
        case .pairing: return "pairing.json"
        case .legacyUnpairOutbox: return "pending_unpair.json"
        case .backgroundWakePlan: return PlannedWakeScheduler.fileName
        case .flowRuntime, .scheduledWakes, .mediaChangeObserver: return nil
        case .autoBackupPrefs: return AutoBackupPrefs.fileName
        case .identity: return "identity.key"
        case .onboardedDesktops: return OnboardedDesktopsStore.fileName
        case .backupScope: return "\(BackupScopeStore.legacyName)-<id>.json"
        case .backupScopeUnpaired: return "\(BackupScopeStore.legacyName).json"
        case .backupSettings: return BackupSettings.fileName
        case .orderDB: return SQLiteOrderStore.fileName
        case .nativeBlobStore: return "iroh-blobs-provider"
        case .flowControl: return FlowControlStore.fileName
        case .notifyOnFailurePrefs: return NotifyOnFailurePrefs.fileName
        case .onboardingNotificationAsk: return OnboardingNotificationAsk.fileName
        case .definitiveNotices: return DefinitiveNoticeStore.fileName
        case .sentinel: return SentinelStore.fileName
        }
    }

    public var disposition: DisconnectDisposition {
        switch self {
        case .pairing, .legacyUnpairOutbox, .backgroundWakePlan: return .clear
        case .flowRuntime, .scheduledWakes, .mediaChangeObserver: return .stop
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
        case .autoBackupPrefs: return "MOB-93：停生产者（autoEnabled=false），留意图（userRequested）"
        case .backgroundWakePlan: return "MOB-93 的 iOS 对位（#340）：后台唤醒计划是生产者的一部分，断开清掉；挂着的系统请求由 scheduledWakes 撤"
        case .scheduledWakes: return "MOB-93 的 iOS 对位：BGTaskScheduler 登记的唤醒是生产者，断开撤掉"
        case .mediaChangeObserver: return "MOB-27/MOB-93 的 iOS 对位：PHPhotoLibrary 变更监听是生产者，断开停掉"
        case .identity: return "红线：密钥就是这台设备（#282）"
        case .onboardedDesktops: return "MOB-114（#455/#461）：「连过这台」必须活过断开；只增不减"
        case .backupScope: return "MOB-92（#266）：相册范围按桌面分，断开不清"
        case .backupScopeUnpaired: return "MOB-92（#266）：未配对时的全局范围，一次性认领的来源，断开不碰"
        case .backupSettings: return "#282 验收 4：Wi-Fi 设置仍保留"
        case .orderDB: return "#413/#415 裁决 6：连回同一台桌面 CONFIRMED 仍有效；换一台由 OrderStore.claimOwner 清"
        case .nativeBlobStore: return "MOB-91 / IOS-07：原生内容仓库断开只 revoke，仓库本身不动"
        case .flowControl: return "\(undecidedBasis)：暂停标志 / 等待原因（#413），Android 断开从来没碰过"
        case .notifyOnFailurePrefs: return "\(undecidedBasis)：设置页「需要处理时通知我」（#130），Android 断开从来没碰过"
        case .onboardingNotificationAsk: return "#130（#515 后续）、#975：通知权限只问一次，之后任何路径（含再走一次 onboarding）都不再问；对位 Android ONBOARDING_NOTIFICATION_ASK"
        case .definitiveNotices: return "#130/#981：失败通知的去重状态（已为哪个配对代号发过、上次相册档位 / 后台刷新状态）；对位 Android definitive_notices.json（KEEP）——清掉会让下次评估把现状当基线重发"
        case .sentinel: return "\(undecidedBasis)：「3 天没连上电脑」哨兵（SENT-01），Android 断开从来没碰过"
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
}

/// 断开（UX-06）与「配对失效重新扫码」共用的清理：按 [DisconnectState] 逐行执行，不依赖桌面是否可达。
/// 某一行失败（清文件出错）不短路后面的行：运行时停止行（provider 撤销、唤醒、相册监听）必须照常执行，
/// 否则「配对文件删不掉」会连带让旧桌面还能拉原图（#974）。所有行跑完后抛出第一个错误，不吞。
public func applyDisconnectManifest(root: URL, runtime: DisconnectRuntime, logger: CoreLogger = NoopLogger(), manifest: [DisconnectState] = DisconnectState.allCases) throws {
    var firstError: Error?
    for state in manifest {
        do {
            switch state.disposition {
            case .keep:
                continue
            case .clear:
                try deleteMatching(root, state)
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
public func unregisteredStatePaths(root: URL, manifest: [DisconnectState] = DisconnectState.allCases) -> [String] {
    var out: [String] = []
    func walk(_ dir: URL, _ prefix: String) {
        let children = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        if children.isEmpty, !prefix.isEmpty { out.append(String(prefix.dropLast())) }
        for name in children {
            let rel = prefix + name
            if manifest.contains(where: { $0.matches(rel) }) { continue }
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
    return out
}
