# NET-18 旧手机/旧桌面兼容降级路径专门验证用例　级别 L1

> ⬜ 状态：未开工 · 协同分支：`main`
> 级别：L1 · 阻塞：无（可立即开工，均为现有代码路径补测试，非新功能）
> **从 [NET-06](NET-06-flow-delivery-async-202-reconcile-ledgers.md) 拆出**：
> NET-06「期望行为⑥ 兼容」的两条分支代码路径都已存在但从未被专门验证，
> 卡内长期标注"未写专门验证的用例，留给下一步"。本卡把两条降级路径的
> 验证一起收尾。完成后回 NET-06 勾掉对应项。

## 问题

NET-06 设计了双向兼容：
1. **新手机 + 旧桌面**（不认 `flow.status`）→ 应降级走旧同步 `fetch()`。
2. **旧手机 + 新桌面** → 旧手机仍调用 `flow.fetch()`（新桌面内部已改为
   等 spawn 的任务，但对外返回语义不变）。

`fetch()` 的公开签名/行为据实施记录声称未变（旧 14 个 `flow_delivery.rs`
集成测试全部保持绿），但没有专门验证：
- 旧手机确实**从不调用** `status`/`suspend`（NET-06 验收标准原文写着
  "**未写专门验证的用例**"）。
- 新手机遇到不支持 `flow.status` 的旧桌面时，确实会**正确降级**为同步
  `fetch()` 而不是卡死或报错。

## 期望行为

两条路径各有一个明确的测试用例，而不是靠"旧测试还是绿的"这种间接证据。

## 验收标准

- [ ] RED 先行（daemon 侧）：模拟"旧手机行为"的测试——只调用 `fetch()`，
      从不调用 `status()`/`suspend()`，断言最终仍正确收敛到 completed，
      且这条路径完全不依赖 `FlowTaskRegistry`/推送事件也能工作（新桌面
      对旧手机的行为对等性）。
- [ ] RED 先行（Android JVM 或对应边界）：模拟"新手机遇旧桌面不支持
      `flow.status`"的场景（例如 daemon 对该 RPC 返回方法不存在/协议
      版本不匹配）→ 断言 `NativeFlowDeliveryPort` 降级为直接同步调用
      `fetch()` 拿回执，不卡在轮询循环里等一个永远不会来的 status 回复。
- [ ] 两个用例都要有反证：去掉降级分支或改变行为，用例必须变红。
- [ ] `cargo test -p daemon --test flow_delivery` 全绿 + Android JVM 全量
      绿（报测试计数）+ `just ci` 全绿。

## 范围

- 只准动：`crates/daemon/tests/flow_delivery.rs`（旧手机行为验证）、
  `apps/android/app/src/test/.../NativeFlowDeliveryPort` 相关测试文件
  （新手机遇旧桌面降级验证；若发现降级分支本身缺失才允许改
  `NativeFlowDeliveryPort.kt`）、卡片/队列文档。
- 不准动：`StrictConsumer` 语义、协议帧格式、`flow.status`/`flow.suspend`
  本身的实现。

## 阻塞与依赖

无前置，无下游。完成后需回写 [NET-06](NET-06-flow-delivery-async-202-reconcile-ledgers.md)
勾掉"旧 fetch 行为兼容"验收项。
