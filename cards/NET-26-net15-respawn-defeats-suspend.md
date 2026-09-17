# NET-26 NET-15 的「重启后重拉丢失任务」把 `flow.suspend` 打坏了（main 现在是红的）

状态：🟥 挂号
级别：L1（两个功能的语义撞在一起，不是测试写法问题）
关联: 由 [NET-15](NET-15-flow-status-must-respawn-a-lost-delivery-task-after-daemon-restart.md)
的实现 `5bdbae4` 引入 · 打坏的是 `flow.suspend`（邻居
[NET-19](NET-19-android-no-competing-offer-and-pause-does-not-observe.md) 管暂停的手机侧）

## 挂号段

- **现象**：`cargo test -p daemon --test flow_delivery
  suspend_interrupts_an_in_progress_fetch_and_keeps_the_grant_active`
  **确定性失败**，`flow_delivery.rs:2021` 断言
  `!status.task_running`（"the interrupted task must be gone from the
  registry"）不成立。**`5bdbae4` 已经在 main 上，所以 main 当前 `just ci` 是红的。**
- **发现场景**：2026-09-17 做 QA-03（门禁）时跑 `just ci` 撞见。QA-03 的改动
  是文档 + `tools/` + `justfile`，**一行 Rust 都没动**，所以这条红与它无关。
- **严重度猜测**：高，而且不是"测试太严"。见下方分析——`status()` 会把用户
  刚暂停的传输**自动恢复**，而手机在等待循环里一直调 `status()`。

## 备注（挂号时已核实，供接卡人省一次考古）

**二分坐实，不是偶发**

    带 5bdbae4（NET-15）        FAILED  3/3
    回退到父提交 8865ea0        ok      2/2

回退方式是只把 `crates/daemon/src/flow_delivery.rs` 取回父提交版本
（`5bdbae4` 只改了这一个文件），测完已原样还原，NET-15 的代码一个字没动。

**根因：两个功能对「active 且没有任务在跑」这个状态的解读正好相反**

- `suspend`（`flow_delivery.rs:1011` 起）的契约是**打断任务、但不碰持久状态**：
  grant 留在 `Active`，`tasks.interrupt(peer, &grant)` 把任务从注册表摘掉。
  于是暂停后的稳定状态就是 **active + 无任务**。
- NET-15 给 `status()` 加的是（`5bdbae4` 的第三个 hunk）：

      if grant.state == FlowGrantState::Active && !self.tasks.is_running(peer, &grant) {
          // daemon 重启会清空内存里的任务注册表 → 重拉丢失的任务

  也就是把 **active + 无任务** 判定为"任务丢了，重拉"。

**这两个状态在现有信息下不可区分**——suspend 刻意制造的，恰好就是 NET-15
认定为"需要重拉"的那一个。后果不止是测试红：

- 手机在等待循环里**持续调 `status()`**（`NativeFlowDeliveryPort` 的
  `CheckStatusNow` 分支）。用户点暂停之后，下一次 status 轮询就会把传输**自动
  恢复**，暂停在产品上失效。
- 这也不是"测试写得太死"：那条断言写的正是 suspend 的产品契约
  （"suspend must leave the grant active, unlike cancel" + 任务必须真的停下）。

**接卡人要拿的拍板（本卡不替验收人决定）**

NET-15 想解决的问题（daemon 重启后任务丢了没人重拉）是真的，不能简单回退。
需要一个能把两种「active + 无任务」区分开的判据，候选方向（都未验证）：

1. 让 suspend 在持久状态里留痕（新增 grant 状态或一个 `suspended_at` 字段），
   `status()` 的重拉条件排除它。改存储 schema。
2. 重拉只在**本进程生命周期内没见过这个 grant** 时才做（进程启动时间 vs
   grant 的 `updated_at`），suspend 是本进程内发生的所以不触发。不改 schema，
   但判据更绕、更容易再撞。
3. 重拉挪出 `status()`，改成 daemon 启动时扫一遍 active grant——与 NET-15
   卡面说的"daemon 重启"场景严格对齐，而 `status()` 回到纯查询。**这条最像
   正解**：`status()` 是手机高频调用的查询接口，让它产生副作用本身就是
   NET-15 引入的新耦合。

## 对 main 的处置建议（当场汇报，等验收人裁决）

main 现在红着，另一个会话可能正在它上面继续开发。建议先按第 3 条方向修
NET-15，或者暂时回退 `5bdbae4` 让 main 转绿再重做——**哪条都由验收人定，
本卡不动别人的代码**。
