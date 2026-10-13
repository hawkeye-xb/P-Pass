// #340（IOS-14）：回到前台补捞（对位 Android MOB-38 的 `foregroundCatchup()` + `triggerUserPresentBackup` 那条 KEEP 唯一任务）。
//
// Android：Activity 走到 ON_RESUME 就补捞一次；补捞是一条 unique work（KEEP）——上一次还没跑完，新的 resume 不再排。
// iOS：App 的 scenePhase 变成 .active 时调 `appDidBecomeActive()`。补捞触发的是 `APP_FOREGROUND`（人在场、带对账），
// 上一轮补捞还没跑完时新的 resume 直接忽略——连续多次回前台只跑一轮。暂停中的引擎只记意图，不消费（C-02）。
import Foundation

public actor ForegroundCatchup {
    private let engine: FlowEngine
    private var inFlight: Task<Void, Never>?
    /// 真正发出去的补捞次数（诊断 / 测试读）。
    public private(set) var issued = 0

    public init(engine: FlowEngine) {
        self.engine = engine
    }

    /// App 回到前台。返回这次是否真的发起了补捞（false = 上一轮补捞还在跑，合并掉了）。
    @discardableResult
    public func appDidBecomeActive() async -> Bool {
        if inFlight != nil { return false }
        issued += 1
        await engine.onAppForeground()
        inFlight = Task { [engine] in
            await engine.awaitIdle()
            await self.markFinished()
        }
        return true
    }

    private func markFinished() async {
        inFlight = nil
    }

    /// 测试用：等这一轮补捞（含它合并进来的触发）跑完。
    public func awaitSettled() async {
        await inFlight?.value
    }
}
