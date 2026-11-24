// #1992：纯内存备份与连接状态机随机序列压测（Fuzzing）
// 测试范围：纯内存 FlowEngine 状态机在快速新增媒体、网络闪断/恢复、自动备份开关切换、
// 权限切换（Full/Partial/Denied/目录失效）、范围变更、对账交错下的核心不变量。
//
// 核心不变量：
// 1. 用户关闭自动备份开关期间，绝不触发新的自动媒体备份传输；
// 2. 最终恢复连通 + 权限 + 开启自动备份后跑一轮对账，范围内有效媒体 100% 收敛到 CONFIRMED 且无重复；
// 3. 状态机无死锁或矛盾非法态（收敛至 idle，无在途孤儿或悬挂）。
// 失败时必须打印 seed 与完整事件追踪，以便 100% 稳定复现。

import Foundation
import XCTest
@testable import PPassCore

/// 简单确定性伪随机数生成器（Linear Congruential Generator，不依赖平台差异，保证跨平台同种子同序列）
private struct SimplePRNG {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0xCAFEF00DDEADBEEF : seed
    }

    mutating func nextUInt64() -> UInt64 {
        // 64-bit LCG 参数 (Knuth MMIX)
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }

    mutating func nextInt(upperBound: Int) -> Int {
        guard upperBound > 0 else { return 0 }
        return Int(nextUInt64() % UInt64(upperBound))
    }

    mutating func nextBool() -> Bool {
        return (nextUInt64() & 1) == 1
    }
}

final class FlowStateMachineRandomFuzzTests: XCTestCase {

    enum FuzzEvent: CustomStringConvertible {
        case addMedia(id: Int, bucket: String)
        case removeMedia(id: Int)
        case networkDrop
        case networkRecover
        case setAutoBackup(Bool)
        case setPermissionFull
        case setPermissionPartial
        case setPermissionRevoked
        case triggerReconcile(TriggerReason)
        case triggerMediaChange

        var description: String {
            switch self {
            case let .addMedia(id, bucket): return "addMedia(id: \(id), bucket: \(bucket))"
            case let .removeMedia(id): return "removeMedia(id: \(id))"
            case .networkDrop: return "networkDrop"
            case .networkRecover: return "networkRecover"
            case let .setAutoBackup(on): return "setAutoBackup(\(on))"
            case .setPermissionFull: return "setPermissionFull"
            case .setPermissionPartial: return "setPermissionPartial"
            case .setPermissionRevoked: return "setPermissionRevoked"
            case let .triggerReconcile(r): return "triggerReconcile(\(r.rawValue))"
            case .triggerMediaChange: return "triggerMediaChange"
            }
        }
    }

    func testRandomStateMachineInterleavingInvariants() async throws {
        // 固定运行 5 个独立 seed，每轮执行 40 步事件交错，总时长严格控制在 5 秒以内
        let baseSeeds: [UInt64] = [199201, 199202, 199203, 199204, 199205]
        let startTime = Date()

        for seed in baseSeeds {
            try await runFuzzIteration(seed: seed, steps: 40)
        }

        let elapsed = Date().timeIntervalSince(startTime)
        XCTAssertLessThanOrEqual(elapsed, 5.0, "Fuzz test took too long: \(elapsed)s > 5.0s")
    }

    private func runFuzzIteration(seed: UInt64, steps: Int) async throws {
        var prng = SimplePRNG(seed: seed)
        var trace: [String] = []

        let rig = try Rig("fuzz-\(seed)")
        await rig.start()

        // 跟踪不变量 ①：用户关闭自动备份期间是否被违规触发自动备份
        let illegalTransferDuringAutoDisabled = Locked<[String]>([])
        rig.delivery.onStart.set { req in
            let isAutoEnabled = rig.autoRule.get()
            if !isAutoEnabled {
                illegalTransferDuringAutoDisabled.update { $0.append(req.details.snapshot.mediaId) }
            }
        }

        var nextPhotoId = 1
        var existingPhotos: [Int] = []
        var nextGeneration: Int64 = 1

        trace.append("SEED=\(seed) START")

        for step in 0..<steps {
            let choice = prng.nextInt(upperBound: 10)
            let event: FuzzEvent

            switch choice {
            case 0, 1, 2: // 新增媒体 (30%)
                let photoId = nextPhotoId
                nextPhotoId += 1
                let bucket = prng.nextBool() ? "B7" : "B8"
                rig.photo(photoId, generation: nextGeneration, bucket: bucket)
                nextGeneration += 1
                existingPhotos.append(photoId)
                event = .addMedia(id: photoId, bucket: bucket)
                trace.append("Step \(step): \(event)")
                await rig.trigger(.mediaChange)

            case 3: // 媒体被外部删除 (10%)
                if let idx = existingPhotos.indices.randomElement(using: &prng) {
                    let photoId = existingPhotos.remove(at: idx)
                    rig.media.remove(photoId)
                    event = .removeMedia(id: photoId)
                } else {
                    event = .triggerMediaChange
                    await rig.trigger(.mediaChange)
                }
                trace.append("Step \(step): \(event)")

            case 4: // 网络断开 (10%)
                rig.probe.result.set(.unreachable)
                rig.presence.unreachable.set(true)
                event = .networkDrop
                trace.append("Step \(step): \(event)")
                await rig.trigger(.networkChange)

            case 5: // 网络恢复 (10%)
                rig.probe.result.set(.reachable(advertisedPairingId: "e1", health: nil, capabilities: []))
                rig.presence.unreachable.set(false)
                event = .networkRecover
                trace.append("Step \(step): \(event)")
                await rig.trigger(.desktopReachable)

            case 6: // 自动备份开关切换 (10%)
                let on = prng.nextBool()
                rig.autoRule.set(on)
                rig.conditions.update { $0.autoBackupEnabled = on }
                event = .setAutoBackup(on)
                trace.append("Step \(step): \(event)")
                await rig.trigger(.appForeground)

            case 7: // 权限 Full (10%)
                rig.media.scope = ["B7", "B8"]
                rig.media.lookupThrows.set(nil)
                rig.media.scanThrows.set(nil)
                event = .setPermissionFull
                trace.append("Step \(step): \(event)")
                await rig.trigger(.scopeAdded)

            case 8: // 权限 Partial / 范围受限 (10%)
                rig.media.scope = ["B7"]
                rig.media.lookupThrows.set(nil)
                rig.media.scanThrows.set(nil)
                event = .setPermissionPartial
                trace.append("Step \(step): \(event)")
                await rig.trigger(.foregroundMediaChange)

            case 9: // 权限失效 / 目录不可用 (10%)
                let err = SourceUnavailable(reason: "fuzz permission revoked")
                rig.media.lookupThrows.set(err)
                rig.media.scanThrows.set(err)
                event = .setPermissionRevoked
                trace.append("Step \(step): \(event)")
                await rig.trigger(.userContinue)

            default:
                event = .triggerMediaChange
                await rig.trigger(.mediaChange)
            }

            // 验证不变量 ①：用户关闭自动备份期间绝不偷跑
            let illegal = illegalTransferDuringAutoDisabled.get()
            XCTAssertTrue(
                illegal.isEmpty,
                "Invariant 1 violated: transfers occurred while auto backup was disabled! Seed: \(seed), transfers: \(illegal)\nTrace:\n\(trace.joined(separator: "\n"))"
            )
        }

        // ==================== 最终收敛阶段 ====================
        trace.append("FINALIZING: restoring ideal conditions for convergence")

        // 恢复全部理想状态：开启自动备份、网络可达、权限 Full、重置异常抛出
        rig.autoRule.set(true)
        rig.conditions.update {
            $0.autoBackupEnabled = true
            $0.paired = true
            $0.onUnmetered = true
            $0.wifiOnly = false
            $0.batteryLow = false
        }
        rig.probe.result.set(.reachable(advertisedPairingId: "e1", health: nil, capabilities: []))
        rig.presence.unreachable.set(false)
        rig.media.scope = ["B7", "B8"]
        rig.media.lookupThrows.set(nil)
        rig.media.scanThrows.set(nil)
        rig.fakeControl?.pausedFlag = false

        // 范围变更恢复：触发 scopeAdded 会让扫描置脏并跑对账，确保此前因不在范围内而跳过或未扫描的照片被完整扫回
        await rig.trigger(.scopeAdded)
        await rig.trigger(.periodic)

        // 验证不变量 ②：范围内所有存在且未删除的有效媒体，最终 100% 收敛到 CONFIRMED，且无重复传输请求
        let deliveredRequests = rig.delivery.requests.get()
        var seenDeliveredMedia = Set<String>()
        var duplicateDeliveries: [String] = []

        for req in deliveredRequests {
            let mid = req.details.snapshot.mediaId
            if seenDeliveredMedia.contains(mid) {
                duplicateDeliveries.append(mid)
            }
            seenDeliveredMedia.insert(mid)
        }

        XCTAssertTrue(
            duplicateDeliveries.isEmpty,
            "Invariant 2 violated: duplicate delivery requests found for same media! Seed: \(seed), duplicates: \(duplicateDeliveries)\nTrace:\n\(trace.joined(separator: "\n"))"
        )

        // 检查所有当前还在 FakeMedia 且在 scope 内的照片
        let expectedPhotos = rig.media.photos.filter { rig.media.isInScope($0.bucket) }
        for photo in expectedPhotos {
            guard let order = try rig.current(photo.n) else {
                XCTFail("Invariant 2 violated: photo \(photo.mediaId) was in scope but has no order! Seed: \(seed)\nTrace:\n\(trace.joined(separator: "\n"))")
                continue
            }
            XCTAssertEqual(
                order.state,
                .confirmed,
                "Invariant 2 violated: in-scope photo \(photo.mediaId) was not confirmed (state=\(order.state.rawValue))! Seed: \(seed)\nTrace:\n\(trace.joined(separator: "\n"))"
            )
        }

        // 验证不变量 ③：状态机收敛，无死锁与未决悬挂
        let view = await rig.engine.view
        let pending = await rig.pending()
        XCTAssertEqual(
            pending,
            0,
            "Invariant 3 violated: pending items remaining after convergence! pending=\(pending), Seed: \(seed)\nTrace:\n\(trace.joined(separator: "\n"))"
        )
        XCTAssertEqual(
            view.state,
            .idle,
            "Invariant 3 violated: engine did not settle to idle (current=\(view.state.rawValue))! Seed: \(seed)\nTrace:\n\(trace.joined(separator: "\n"))"
        )
    }
}

// 帮助支持 Array.randomElement(using: &SimplePRNG)
extension SimplePRNG: RandomNumberGenerator {
    mutating func next() -> UInt64 {
        return nextUInt64()
    }
}
