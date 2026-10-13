import Foundation
import PPassCore

// 首页（「设置」tab）的裁决——纯函数，逐条移植 Android：
//   ui/BackupStatus.kt（StatusLine / HeroAction / LastSuccess）
//   ui/HomeScreen.kt（BackupUiState / HeroRender / 规则 G、S）
//   backup/ConfirmedStore.kt（BackupTriplet / tripletOf）
//   backup/flow/FlowUiProjection.kt（backupUiStateOf / flowAllDone / roundOrdinalOf）
// 两条铁律各有 XCTest 锁死（HomeProjectionTests）：
//   (a) 待备份 K > 0 时永不说「照片都存好了」；(b) 从未成功（ts ≤ 0）永不渲染日期。
// 视图只做「裁决 → 颜色 / 文案 key」的映射。

/// 相册授权三档（对位 Android `MediaAccess`；iOS 由 PPassMedia 的授权模型映射而来）。
enum MediaAccess: Equatable { case full, partial, none }

/// 引擎视图里首页要用的那几项（PPassCore.EngineView 没有公开构造器，假数据源与适配器都填这个）。
struct EngineSnapshot: Equatable {
    var state: GlobalState = .idle
    var waitReason: WaitReason?
    var pending: Int = 0
    var doneThisRound: Int = 0
    var currentFileName: String?
    var desktopFreeBytes: Int64?

    init(state: GlobalState = .idle, waitReason: WaitReason? = nil, pending: Int = 0, doneThisRound: Int = 0,
         currentFileName: String? = nil, desktopFreeBytes: Int64? = nil) {
        self.state = state
        self.waitReason = waitReason
        self.pending = pending
        self.doneThisRound = doneThisRound
        self.currentFileName = currentFileName
        self.desktopFreeBytes = desktopFreeBytes
    }

    init(_ view: EngineView) {
        self.init(state: view.state, waitReason: view.waitReason, pending: view.pending,
                  doneThisRound: view.doneThisRound, currentFileName: view.current?.fileName,
                  desktopFreeBytes: view.desktopHealth?.freeBytes)
    }
}

/// 首页需要的全部事实（对位 Android `FlowProjection`）。
struct FlowFacts: Equatable {
    /// nil = 引擎还没算出待办（英雄区不先说「都存好了」）。
    var view: EngineSnapshot?
    var confirmed: Int64 = 0
    var inScopeTotal: Int64?
    var failed: Int64 = 0
    var unfinished: Int64 = 0
    var lastSuccessAt: Int64 = 0
    var missingSourceUnacknowledged: Int64 = 0
    var skippedByUser: Int64 = 0

    var state: GlobalState { view?.state ?? .idle }
    var waitReason: WaitReason? { state == .waiting ? view?.waitReason : nil }
    var remaining: Int64? { view.map { Int64($0.pending) } }
    var paused: Bool { state == .paused }

    /// m = n − 待办 − 范围内已跳过，夹在 [0, n]；n 或待办未知时退回 confirmed。
    var done: Int64 {
        guard let n = inScopeTotal, let k = remaining else { return confirmed }
        return min(max(n - k - skippedByUser, 0), n)
    }
}

enum BackupUiState: Equatable {
    case idle, preparing, paused, noAlbums
    case sending(done: Int, total: Int, currentFile: String)
    case allSafe(ingested: Int)
    case waiting(WaitReason)
    case trouble(String)

    var isRunning: Bool {
        switch self {
        case .preparing, .sending: return true
        default: return false
        }
    }
}

enum StatusLine: Equatable { case ready, working, pending(Int64), allSafe, noAlbums, trouble, waiting, paused }
enum HeroAction: Equatable { case pause, resume }
enum HeroRender: Equatable { case accessBlocked, unreadable, unreconciled, triplet }

enum LastSuccess: Equatable {
    case never, justNow
    case minutesAgo(Int64), hoursAgo(Int64)
    case at(Int64)
}

struct BackupTriplet: Equatable {
    let n: Int64
    let m: Int64
    let lastSuccessAt: Int64
    let confirmedRaw: Int64
    var hasFailedNeedsUser = false
    var pausedByUser = false
    var remaining: Int64?
    var skippedByUser: Int64 = 0
    var k: Int64 { max(remaining ?? (n - m), 0) }
}

enum HomeProjection {
    static func tripletOf(n: Int64, confirmed: Int64, lastSuccessAt: Int64, hasFailedNeedsUser: Bool = false,
                          pausedByUser: Bool = false, remaining: Int64? = nil, skippedByUser: Int64 = 0) -> BackupTriplet {
        BackupTriplet(n: n, m: min(confirmed, n), lastSuccessAt: lastSuccessAt, confirmedRaw: confirmed,
                      hasFailedNeedsUser: hasFailedNeedsUser, pausedByUser: pausedByUser,
                      remaining: remaining, skippedByUser: skippedByUser)
    }

    /// 范围从未保存或 n 读不到 → nil（英雄区说「读不到」）。
    static func triplet(_ f: FlowFacts, scopeSaved: Bool) -> BackupTriplet? {
        guard scopeSaved, let n = f.inScopeTotal else { return nil }
        return tripletOf(n: n, confirmed: f.done, lastSuccessAt: f.lastSuccessAt, hasFailedNeedsUser: f.failed > 0,
                         pausedByUser: f.paused, remaining: f.remaining, skippedByUser: f.skippedByUser)
    }

    static func backupUiState(_ f: FlowFacts, noAlbums: Bool) -> BackupUiState {
        switch f.state {
        case .paused: return .paused
        case .running:
            guard let v = f.view, let file = v.currentFileName else { return .preparing }
            let (x, y) = roundOrdinal(doneThisRound: v.doneThisRound, pending: v.pending)
            return .sending(done: x, total: y, currentFile: file)
        case .waiting:
            if let r = f.waitReason, r != .notPaired { return .waiting(r) }
            return idleState(f, noAlbums: noAlbums)
        case .idle:
            return idleState(f, noAlbums: noAlbums)
        }
    }

    private static func idleState(_ f: FlowFacts, noAlbums: Bool) -> BackupUiState {
        if noAlbums { return .noAlbums }
        if f.failed > 0 { return .trouble("flow.failed=\(f.failed)") }
        if allDone(f) { return .allSafe(ingested: Int(f.done)) }
        return .idle
    }

    static func allDone(_ f: FlowFacts) -> Bool {
        if let k = f.remaining, f.inScopeTotal != nil { return k == 0 && f.done > 0 }
        if f.confirmed <= 0 || f.unfinished != 0 { return false }
        if let k = f.remaining { return k == 0 }
        return f.inScopeTotal.map { f.confirmed >= $0 } ?? true
    }

    static func roundOrdinal(doneThisRound: Int, pending: Int) -> (Int, Int) {
        let done = max(doneThisRound, 0) + 1
        return (done, max(max(doneThisRound, 0) + max(pending, 0), done))
    }

    /// 优先级：失败 > 进行中 > 欠账 > 成功 > 就绪。铁律 (a)：K > 0 拦在 AllSafe 之前。
    static func statusLine(_ s: BackupUiState, pendingK: Int64) -> StatusLine {
        switch s {
        case .trouble: return .trouble
        case .preparing, .sending: return .working
        case .noAlbums: return .noAlbums
        case .waiting: return .waiting
        case .paused: return .paused
        case .idle, .allSafe:
            if pendingK > 0 { return .pending(pendingK) }
            if case .allSafe = s { return .allSafe }
            return .ready
        }
    }

    static func heroAction(_ s: BackupUiState, pairingLost: Bool) -> HeroAction? {
        if pairingLost { return nil }
        if s.isRunning { return .pause }
        if s == .paused { return .resume }
        return nil
    }

    /// 铁律 (b)：ts ≤ 0 一律 Never，日期分支拿不到 epoch 0。
    static func lastSuccess(ts: Int64, now: Int64) -> LastSuccess {
        if ts <= 0 { return .never }
        let mins = (now - ts) / 60_000
        if mins < 1 { return .justNow }
        if mins < 60 { return .minutesAgo(mins) }
        if mins < 60 * 24 { return .hoursAgo(mins / 60) }
        return .at(ts)
    }

    /// 规则 H：权限不全 → 引导卡顶替整块数字（MOB-02/MOB-94：不显示任何数，就不可能盖「都存好了」的章）。
    static func heroRender(_ access: MediaAccess, _ t: BackupTriplet?) -> HeroRender {
        if access != .full { return .accessBlocked }
        guard let t else { return .unreadable }
        if t.confirmedRaw > t.n { return .unreconciled }
        return .triplet
    }

    /// 规则 G：主数字为绿，当且仅当五条同时成立。
    static func heroNumberIsSafe(_ access: MediaAccess, _ t: BackupTriplet?, pairingLost: Bool) -> Bool {
        guard access == .full, let t, !pairingLost else { return false }
        return !t.hasFailedNeedsUser && !t.pausedByUser
    }

    /// 规则 S：「照片都存好了」= 规则 G + 不在「对不上」+ 无缺源 + 范围内没有用户跳过的。
    static func allSafeTextAllowed(_ access: MediaAccess, _ t: BackupTriplet?, pairingLost: Bool, missingSource: Int64) -> Bool {
        heroNumberIsSafe(access, t, pairingLost: pairingLost)
            && heroRender(access, t) != .unreconciled
            && missingSource == 0
            && (t?.skippedByUser ?? 0) == 0
    }

    /// 等待原因 → 状态行那句话（Android `waitReasonTextRes`；iOS 新增的两个原因走 iOS 文案）。
    static func waitTextKey(_ r: WaitReason) -> String {
        switch r {
        case .notPaired, .disabled: return "state_waiting_disabled"
        case .wifi: return "wifi_deferred_hint"
        case .battery: return "state_waiting_battery"
        case .executionBlocked: return "state_waiting_execution_blocked"
        case .desktopUnreachable: return "state_waiting_desktop_unreachable"
        case .desktopStorageFull: return "state_waiting_desktop_full"
        case .desktopLibraryUnavailable: return "state_waiting_desktop_library"
        case .desktopStorageError: return "state_waiting_desktop_error"
        case .unexpectedError: return "state_waiting_unexpected_error"
        case .originalUnavailable: return "state_waiting_original_unavailable"
        }
    }
}
