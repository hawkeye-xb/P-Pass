# NET-22 rebind 一个已完成的 Flow grant 必须补推送，不能只静默复用　级别 L1

> ✅ 状态：已修复并通过 `cargo test -p daemon --test flow_delivery`（29/29）· 协同分支：`main`
> 级别：L1 · 阻塞：无

## 问题

`offer_inner`（`crates/daemon/src/flow_delivery.rs`）里 `rebind_completed_flow_grant`
命中时（同一 `queue_sequence` 在新的 `lease_token`/`provider` 下重新 offer，
但这条 tuple 早就传完过——典型场景：重新配对/重装后发现游标又从头
扫描到同一个 `queue_sequence`），历史实现只是静默把这一行 rebind 到新
`lease_token`，直接返回 `Ok(())`——没有推送、没有唤醒调用方。

NET-20 那条姊妹分支（`complete_without_fetch`，命中内容库去重时）已经
会 `emit_flow_delivered` 推送给手机；这条 rebind 分支是**同一个"已经
有了，告诉你"的事实**，却没有做同样的事，只能靠手机侧「本地空闲兜底
轮询」兜底。真机 2026-09-16 复现：一个 daemon 早就知道 receipt 的场景，
手机侧硬等了 30 秒本地空闲超时才靠 `flow.status()` 兜底轮询捞回来——
一次不必要的、可完全避免的延迟。

## 实现

`offer_inner` 命中 `rebind_completed_flow_grant` 后，取回 rebind 后的
grant 与其持久 receipt，调用与 NET-20 分支完全相同的
`self.emit_flow_delivered(peer, &rebound, &receipt)` 再返回，行为与
"刚完成的一次去重"对手机侧完全一致。

## 验收标准

- [x] RED 先行：`reoffering_an_already_completed_tuple_under_a_new_lease_still_pushes_flow_delivered`
      ——同一 `queue_sequence` 先正常传完一次，再用新 `lease_token`/`provider`
      重新 offer，断言这次 offer 立刻收到 `flow.delivered` 推送，而不是
      只能等轮询。
- [x] `cargo test -p daemon --test flow_delivery` 29/29（28 原有 + 1 新增）。

## 范围

- 只动：`crates/daemon/src/flow_delivery.rs`（`offer_inner` 的 rebind 分支）、
  `crates/daemon/tests/flow_delivery.rs`（1 条新测试）。
- 未动：Android 侧代码、协议线格式、NET-20/NET-21 的其余逻辑。

## 阻塞与依赖

无前置。与 NET-23（手机侧等待循环的兜底超时缺口）同一次真机复现中
一起发现，两者互相独立、任一个单独合并都不依赖对方。

## 备注

本卡本身**不能**解决"本地 iroh 从未有任何活动时兜底轮询永远不触发"
这一类缺口——那是手机侧的问题，见 [NET-23](NET-23-flow-wait-loop-must-not-hang-forever-when-local-signal-never-fires.md)。
真机复现时这条 rebind 分支实际并未命中（复现路径是 NET-20 的
`complete_without_fetch` 分支，其自身的推送也可能因订阅时机丢失）；
本卡是复核代码时发现的同类缺口，一并补上。
