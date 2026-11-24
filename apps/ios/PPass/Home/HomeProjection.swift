import Foundation
import PPassCore

enum MediaAccess: Equatable { case full, partial, none }

struct EngineSnapshot: Equatable {
    var state: GlobalState = .idle
    var waitReason: WaitReason?
    var pending: Int = 0
    var doneThisRound: Int = 0
    var currentFileName: String?
    var desktopFreeBytes: Int64?
    var currentOrderId: Int64?
    var currentBytesSent: Int64 = 0
    var currentTotalBytes: Int64 = 0
    var fetchingFileName: String?
    var fetchingFromICloud = false
    var fetchingFraction: Double?

    init(state: GlobalState = .idle, waitReason: WaitReason? = nil, pending: Int = 0, doneThisRound: Int = 0,
         currentFileName: String? = nil, desktopFreeBytes: Int64? = nil,
         currentOrderId: Int64? = nil, currentBytesSent: Int64 = 0, currentTotalBytes: Int64 = 0) {
        self.currentOrderId = currentOrderId
        self.currentBytesSent = currentBytesSent
        self.currentTotalBytes = currentTotalBytes
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
                  desktopFreeBytes: view.desktopHealth?.freeBytes,
                  currentOrderId: view.current?.orderId, currentBytesSent: view.current?.bytesSent ?? 0,
                  currentTotalBytes: view.current?.totalBytes ?? 0)
        fetchingFileName = view.fetching?.fileName
        fetchingFromICloud = view.fetching?.fromICloud ?? false
        fetchingFraction = view.fetching?.fraction
    }
}

struct FlowFacts: Equatable {
    var view: EngineSnapshot?
    var confirmed: Int64 = 0
    var inScopeTotal: Int64?
    var failed: Int64 = 0
    var unfinished: Int64 = 0
    var lastSuccessAt: Int64 = 0
    var lastReachableAt: Int64 = 0
    var missingSourceUnacknowledged: Int64 = 0
    var skippedByUser: Int64 = 0
    var missingSourceAcknowledged: Int64 = 0
    var countsReadable = true

    var state: GlobalState { view?.state ?? .idle }
    var waitReason: WaitReason? { state == .waiting ? view?.waitReason : nil }
    var remaining: Int64? { view.map { Int64($0.pending) } }
    var paused: Bool { state == .paused }

    var done: Int64 {
        guard let n = inScopeTotal, let k = remaining else { return confirmed }
        return min(max(n - k - skippedByUser, 0), n)
    }
}

enum BackupUiState: Equatable {
    case idle, preparing, paused, noAlbums
    case sending(done: Int, total: Int, currentFile: String)
    case fetchingFromICloud(done: Int, total: Int, currentFile: String, fraction: Double?)
    case allSafe(ingested: Int)
    case waiting(WaitReason)
    case trouble(String)

    var isRunning: Bool {
        switch self {
        case .preparing, .sending, .fetchingFromICloud: return true
        default: return false
        }
    }
}

enum StatusLine: Equatable { case ready, working, pending(Int64), allSafe, noAlbums, trouble, waiting, paused }
enum HeroAction: Equatable { case pause, resume }
enum HeroRender: Equatable {
    case accessBlocked
    case mixedAlbumIncomplete
    case countsUnreadable, noAlbums, unreadable, unreconciled, triplet
}

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
    static func pickedLine(_ batch: PickedBatchSummary?) -> String? {
        guard let batch, !batch.interrupted else { return nil }
        if batch.open > 0 { return L.f("picked_progress", batch.settled + 1, batch.total) }
        let reached = batch.delivered + batch.alreadyThere
        let head: String? = reached == 0 ? nil
            : L.f("picked_result_delivered", reached)
        let tail = batch.failed > 0 ? L.f("picked_result_failed", batch.failed) : nil
        let line = [head, tail].compactMap { $0 }.joined(separator: " · ")
        return line.isEmpty ? nil : line
    }

    static func pickedInterruptedLine(_ batch: PickedBatchSummary?) -> String? {
        guard let batch, batch.interrupted, batch.notReached > 0 else { return nil }
        return L.f("picked_interrupted", batch.total, batch.notReached)
    }

    static func tripletOf(n: Int64, confirmed: Int64, lastSuccessAt: Int64, hasFailedNeedsUser: Bool = false,
                          pausedByUser: Bool = false, remaining: Int64? = nil, skippedByUser: Int64 = 0) -> BackupTriplet {
        BackupTriplet(n: n, m: min(confirmed, n), lastSuccessAt: lastSuccessAt, confirmedRaw: confirmed,
                      hasFailedNeedsUser: hasFailedNeedsUser, pausedByUser: pausedByUser,
                      remaining: remaining, skippedByUser: skippedByUser)
    }

    static func triplet(_ f: FlowFacts, scopeSaved: Bool) -> BackupTriplet? {
        guard f.countsReadable, scopeSaved, let n = f.inScopeTotal else { return nil }
        return tripletOf(n: n, confirmed: f.done, lastSuccessAt: f.lastSuccessAt, hasFailedNeedsUser: f.failed > 0,
                         pausedByUser: f.paused, remaining: f.remaining, skippedByUser: f.skippedByUser)
    }

    static func backupUiState(_ f: FlowFacts, noAlbums: Bool) -> BackupUiState {
        switch f.state {
        case .paused: return .paused
        case .running:
            guard let v = f.view, let file = v.currentFileName ?? v.fetchingFileName else { return .preparing }
            let (x, y) = roundOrdinal(doneThisRound: v.doneThisRound, pending: v.pending)
            if v.currentFileName == nil, v.fetchingFromICloud {
                return .fetchingFromICloud(done: x, total: y, currentFile: file, fraction: v.fetchingFraction)
            }
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
        if !f.countsReadable { return .idle }
        if f.failed > 0 { return .trouble("flow.failed=\(f.failed)") }
        if allDone(f) { return .allSafe(ingested: Int(f.done)) }
        return .idle
    }

    static func allDone(_ f: FlowFacts) -> Bool {
        guard f.countsReadable else { return false }
        if let k = f.remaining, f.inScopeTotal != nil { return k == 0 && f.done > 0 }
        if f.confirmed <= 0 || f.unfinished != 0 { return false }
        if let k = f.remaining { return k == 0 }
        return f.inScopeTotal.map { f.confirmed >= $0 } ?? true
    }

    static func roundOrdinal(doneThisRound: Int, pending: Int) -> (Int, Int) {
        let done = max(doneThisRound, 0) + 1
        return (done, max(max(doneThisRound, 0) + max(pending, 0), done))
    }

    static func statusLine(_ s: BackupUiState, pendingK: Int64) -> StatusLine {
        switch s {
        case .trouble: return .trouble
        case .preparing, .sending, .fetchingFromICloud: return .working
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

    static func heroAction(_ s: BackupUiState, connection: ConnectionState) -> HeroAction? {
        heroAction(s, pairingLost: connection.needsRepair)
    }

    static func lastSuccess(ts: Int64, now: Int64) -> LastSuccess {
        if ts <= 0 { return .never }
        let mins = (now - ts) / 60_000
        if mins < 1 { return .justNow }
        if mins < 60 { return .minutesAgo(mins) }
        if mins < 60 * 24 { return .hoursAgo(mins / 60) }
        return .at(ts)
    }

    static func heroRender(_ access: MediaAccess, _ t: BackupTriplet?, countsReadable: Bool = true, scopeSaved: Bool = true,
                           hasUsableSource: Bool = false, hasSelectedAlbum: Bool = true, mixedAlbumIncomplete: Bool = false) -> HeroRender {
        if access != .full {
            if mixedAlbumIncomplete { return .mixedAlbumIncomplete }
            if !hasUsableSource && hasSelectedAlbum { return .accessBlocked }
        }
        if !countsReadable { return .countsUnreadable }
        guard let t else { return scopeSaved ? .unreadable : .noAlbums }
        if t.confirmedRaw > t.n { return .unreconciled }
        return .triplet
    }

    static func heroNumberIsSafe(_ access: MediaAccess, _ t: BackupTriplet?, pairingLost: Bool) -> Bool {
        guard access == .full, let t, !pairingLost else { return false }
        return !t.hasFailedNeedsUser && !t.pausedByUser
    }

    static func heroNumberIsSafe(_ access: MediaAccess, _ t: BackupTriplet?, connection: ConnectionState) -> Bool {
        heroNumberIsSafe(access, t, pairingLost: connection.needsRepair)
    }

    static func allSafeTextAllowed(_ access: MediaAccess, _ t: BackupTriplet?, pairingLost: Bool, missingSource: Int64) -> Bool {
        heroNumberIsSafe(access, t, pairingLost: pairingLost)
            && heroRender(access, t) != .unreconciled
            && missingSource == 0
            && (t?.skippedByUser ?? 0) == 0
    }

    static func allSafeTextAllowed(_ access: MediaAccess, _ t: BackupTriplet?, connection: ConnectionState, missingSource: Int64) -> Bool {
        allSafeTextAllowed(access, t, pairingLost: connection.needsRepair, missingSource: missingSource)
    }

    static func settingsAlert(connection: ConnectionState, hasBackgroundNotice: Bool) -> Bool {
        connection.needsRepair || hasBackgroundNotice
    }

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
        case .localStorageFull: return "state_waiting_local_storage_full"
        case .desktopInternal: return "state_waiting_desktop_internal"
        case .phoneOutdated: return "state_waiting_phone_outdated"
        case .desktopOutdated: return "state_waiting_desktop_outdated"
        case .sourceUnavailable: return "state_waiting_source_unavailable"
        }
    }
}

enum TransferText {
    static func bytes(_ sent: Int64, _ total: Int64) -> String? {
        guard total > 0 else { return nil }
        let (div, unit): (Double, String) = total >= 1_000_000_000 ? (1e9, "GB") : total >= 1_000_000 ? (1e6, "MB") : (1e3, "KB")
        func fmt(_ v: Int64) -> String {
            if v <= 0 { return "0" }
            let x = Double(v) / div
            return String(format: x >= 100 ? "%.0f" : "%.1f", x)
        }
        return "\(fmt(min(max(sent, 0), total))) / \(fmt(total)) \(unit)"
    }

    static let slowAfterSeconds = 15

    static func isFinishing(sent: Int64, total: Int64) -> Bool { total > 0 && sent >= total }
}

extension FlowFacts {
    func applying(counts: Result<OrderCounts, Error>) -> FlowFacts {
        var f = self
        switch counts {
        case .success(let c):
            f.countsReadable = true
            f.confirmed = c.confirmed
            f.failed = c.byState[.failed] ?? 0
            f.unfinished = (c.byState[.pending] ?? 0) + (c.byState[.transferring] ?? 0) + (c.byState[.failed] ?? 0)
            f.lastSuccessAt = c.lastSuccessAt
            f.missingSourceUnacknowledged = c.missingSourceUnacknowledged
            f.skippedByUser = c.byState[.skippedByUser] ?? 0
            f.missingSourceAcknowledged = c.missingSourceAcknowledged
        case .failure:
            f.countsReadable = false
            f.confirmed = 0; f.failed = 0; f.unfinished = 0; f.lastSuccessAt = 0
            f.missingSourceUnacknowledged = 0; f.skippedByUser = 0; f.missingSourceAcknowledged = 0
        }
        return f
    }
}
