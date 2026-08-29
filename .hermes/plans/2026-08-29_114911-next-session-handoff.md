# 下一 session 交接：P-Pass 备份设计（仅讨论，不实施）

## 启动指令

本 session 只继续设计讨论：**不改生产代码、不跑实现、不提交、不推送，除非用户再次明确要求。**

先读：

- 当前唯一规范：`2026-08-29_114911-backup-core-flow-decision-record-zh-CN.md`
- 历史探索稿仅作背景，不可覆盖当前规范。

已固定，不重复争论：

```text
- 单张文件是最小传输、确认、失败、暂停单位；批次仅用于发现分页/运行汇总/审计汇总。
- 队列和状态存在手机本地 SQLite/Room，不在 Desktop。
- 发现器与上传消费者分离。
- DiscoveryCursor 与 UploadCursor 分离。
- 发现窗口为 500；窗口未完成时新触发只置 discoveryRequested，窗口终态后再发现下一窗。
- 上传消费者严格按 UploadCursor 单张处理；Pause、Retry、上传中均不跨过队头。
- Pause 只暂停消费者；发现下一窗的 materialize 等当前窗口结束。
- hash 仅在轮到单张上传时查缓存/计算；发现阶段不算 hash、不问远端。
- Wi‑Fi/电量/连接条件只让消费者自动等待；用户 Pause 只能由 Continue 恢复。
- 远端对账独立低频分页，不是正常上传前置步骤。
- Desktop 外部缺失默认只标 NEEDS_DECISION，不自动补传，也不自动删除手机原图。
```

## 下一 session 首个议题

### 当前 #18 上传中被 Pause：Desktop staging 的协议

需要决定并验证：

```text
1. Desktop staging 是否有稳定 attemptId / stagingId？
2. 是否能读到经过校验的连续 byte offset / chunk map？
3. 本地媒体版本未变时，能否可靠从 offset 继续？
4. 若不能，是否有显式、幂等的 abort / cleanup？
5. cleanup 未完成时，当前 #18 如何保持严格队头而不误判成功？
```

结论目标：

```text
- 若协议能证明 offset 与分块完整性：允许字节级续传。
- 否则：逻辑上仍从 #18 继续，但从文件起点重新传；partial staging 仅作待清理垃圾，绝不作成功证据。
```

## 后续议题顺序

1. #18 的暂停/续传/abort 协议。
2. Desktop 缺失后的用户通知、恢复、保持删除与未来 tombstone 语义。
3. 远端对账周期、页大小、Desktop 库变化触发与 ReconciliationCursor。
4. 500 窗口的真机压测指标与参数调整。
5. 将当前规范重整为可执行 case catalog；之后才开始 TDD 与数据库 schema 设计。
6. 审计事件模型与 Desktop 汇总展示。

## 关闭本 session 前

若本轮形成新结论：

```text
- 只更新当前唯一规范中的对应章节；不要把结论散写到旧探索稿。
- 标明“已定”与“待定”，不把推测写成结论。
- 新增/调整 case 后，说明它覆盖哪个状态转换。
- 未得到用户明确许可前，不进入代码实现或 Git 推送。
```
