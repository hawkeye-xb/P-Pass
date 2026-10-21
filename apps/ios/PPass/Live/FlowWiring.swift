import Foundation
import PPassCore

/// 引擎回调的真实接线（#966 / #967 / #970）。引擎构造参数不再有默认空闭包，这里是 App 侧唯一的实现。
enum FlowWiring {
    /// 同一台电脑换了配对代号（`hello` 里宣布了新 epoch）：只更新配对记录里的 epoch，order 账本不动
    /// （内容寻址，CONFIRMED 跨代号成立）。对位 Android `AndroidFlowRuntime` 的 `onEpochAdvertised`。写盘失败记日志。
    static func epochAdvertised(store: PairingStore, logger: CoreLogger) -> @Sendable (String) -> Void {
        { advertised in
            do {
                try store.update { if $0.pairingEpoch != advertised { $0.pairingEpoch = advertised } }
            } catch {
                logger.log("epoch advertised: cannot persist new pairing epoch (\(error))")
            }
        }
    }

    /// 一轮结束后冲刷审计 outbox（`flow.audit.submit`，桌面确认的才删）。对位 Android `afterCycle = { auditScope.launch { dispatcher.flush() } }`：
    /// 不挂在引擎收尾上——冲刷走网络，不能卡住「取消剩余」，也不占后台执行窗口；outbox 是持久的，没冲完下一轮接着冲。
    /// 没有配对记录就不冲（`desktop` 返回 nil）。
    static func afterCycle(dispatcher: AuditOutboxDispatcher) -> @Sendable () async -> Void {
        { Task.detached { await dispatcher.flush() } }
    }

    /// 审计冲刷用的桌面：已配对才有。
    static func auditDesktop(store: PairingStore, desktop: FlowDesktop) -> @Sendable () -> FlowDesktop? {
        { store.load() == nil ? nil : desktop }
    }
}

/// 空 epoch 的老配对修复（对位 Android `needsEpochRepair` / `applyEpochRepairOutcome` / `repairEpochIfNeeded`，#970）。
func needsEpochRepair(_ pairingEpoch: String) -> Bool { pairingEpoch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

enum EpochRepairResult: Equatable {
    case repaired(String)
    case lost
    /// #1072 / #1073：电脑版本不兼容——不是对配对的判决；不写盘，更新之后再修一次。
    case deferred
}

/// `outcome` = 向桌面问当前 epoch 的结果（同一个 `hello`）。成功但 epoch 为空与失败同等对待：桌面自己也给不出，没有可修的目标。
func applyEpochRepairOutcome(_ outcome: Result<String?, Error>) -> EpochRepairResult {
    if case .failure(let error) = outcome, let rejected = error as? DesktopRejected, case .versionMismatch = rejected.reasonClass { return .deferred }
    if case .success(let epoch?) = outcome, !needsEpochRepair(epoch) { return .repaired(epoch) }
    return .lost
}

/// 每个进程只试一次。修好 → 写回 epoch；修不了 → 标失联（首页引导重新配对，而不是停在「未配对」里不探测、不备份）。
final class EpochRepairer: @unchecked Sendable {
    private let store: PairingStore
    private let hello: @Sendable () async throws -> String?
    private let logger: CoreLogger
    private let lock = NSLock()
    private var attempted = false

    init(store: PairingStore, hello: @escaping @Sendable () async throws -> String?, logger: CoreLogger) {
        self.store = store
        self.hello = hello
        self.logger = logger
    }

    /// 没有要修的（没配对 / 已失联 / epoch 非空 / 本进程试过了）返回 nil。
    func repairIfNeeded() async -> EpochRepairResult? {
        guard let record = store.load(), !record.lost, needsEpochRepair(record.pairingEpoch), claim() else { return nil }
        let outcome: Result<String?, Error>
        do { outcome = .success(try await hello()) } catch { outcome = .failure(error) }
        let result = applyEpochRepairOutcome(outcome)
        if result == .deferred {
            release()
            logger.log("epoch repair: protocol version mismatch; not a verdict on the pairing, will retry after an update")
            return result
        }
        do {
            switch result {
            case .repaired(let epoch): try store.update { $0.pairingEpoch = epoch }
            case .lost: try store.markLost()
            case .deferred: break // 上面已提前返回
            }
        } catch {
            logger.log("epoch repair: cannot persist \(result) (\(error))")
        }
        if case .failure(let error) = outcome { logger.log("epoch repair: hello failed (\(error)); pairing marked lost") }
        return result
    }

    private func release() {
        lock.lock(); defer { lock.unlock() }
        attempted = false
    }

    private func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if attempted { return false }
        attempted = true
        return true
    }
}
