import Foundation
import PPassCore

/// 引擎回调的真实接线（#966 / #967 / #970）。引擎构造参数不再有默认空闭包，这里是 App 侧唯一的实现。
enum FlowWiring {
    /// 引擎在探测里看到 `hello` 宣布的配对代号与本地不一致（#1119）：与 `pairing_mismatch` 是同一个事实——电脑当前认的不是本地这条配对，
    /// 按被拒处理（记进 [PairingLoss]，由被拒即清理删本地配对），不再把新代号写回本地记录（那等于替电脑认下一条本机没有走过配对流程的关系）。
    /// 正常情况下走不到：`ControlPlaneDesktop.hello` 在更靠前的位置就把这种应答变成了拒绝；这里是引擎一侧的同一口径兜底。
    static func pairingIdAdvertised(loss: PairingLoss, currentPairingId: @escaping @Sendable () -> String?) -> @Sendable (String) -> Void {
        { _ in
            if let local = currentPairingId() { loss.markLost(pairingId: local) }
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
