# NET-26 `status()` 的重拉与 `flow.suspend` 语义相撞——目前无生产影响，但装着一个静默陷阱

状态：🟥 挂号
级别：L2（降级过一次，理由见「更正记录」；接口当前零调用，接上就会踩）
关联: 由 [NET-15](done/NET-15-flow-status-must-respawn-a-lost-delivery-task-after-daemon-restart.md)
的实现引入并由其后续提交定型 · 邻居
[NET-19](NET-19-android-no-competing-offer-and-pause-does-not-observe.md)（暂停的手机侧）

## 挂号段

- **现象**：`flow.suspend` 的契约是「打断正在跑的 fetch 任务、但 grant 留在
  `active`」（`flow_delivery.rs:1011` 起，`tasks.interrupt`）；NET-15 给
  `status()` 加的重拉条件是「grant 为 `active` 且没有任务在跑 → 任务丢了，
  重拉」。**suspend 刻意制造的稳定状态，恰好就是重拉判据认定"需要重拉"的那一个**
  ——两者在现有信息下不可区分。
- **发现场景**：2026-09-17 做 QA-03（门禁）时跑 `just ci` 撞见
  `suspend_interrupts_an_in_progress_fetch_and_keeps_the_grant_active`
  确定性失败（3/3）。二分坐实是 NET-15 那个提交引入：只把
  `crates/daemon/src/flow_delivery.rs` 取回父提交版本后 2/2 转绿，测完原样还原。
- **严重度猜测**：中。**当前没有生产影响**——`flow.suspend` 全仓零生产调用方
  （见备注）。风险是latent：哪天有人把暂停按钮接到 `flow.suspend` 上，它会
  静默地不起作用，而现在的测试还会为这个行为背书。

## 备注（挂号时已核实，供接卡人省一次考古）

**`flow.suspend` 目前没有任何生产调用方**

    crates/proto/src/msgs.rs:532          方法常量定义
    crates/daemon/src/router.rs:571       daemon 侧实现（在跑）
    apps/android/.../DaemonClient.kt:176  客户端方法 flowSuspend()
    → 全仓 grep `flowSuspend` 只有定义那一行，**零调用**

手机的暂停走的是另一条路：`NativeFlowDeliveryPort.stop()`（`:483`）调
`desktopFor(currentPairing).cancel(current.request)`，然后 `active = null`
结束等待循环。**是 `cancel`，不是 `suspend`。**

**并行会话已经把测试改绿了，改法是把断言反过来**

`b8c98a6` 把那条断言从 `!status.task_running` 改成 `status.task_running`，
即正式接受「status() 会把被 suspend 打断的任务重拉起来」。鉴于上面那条
（接口零调用），这个改法是站得住的——它给一个没人调的接口定了新语义。
截至本卡写成时 **main 是绿的**：`cargo nextest run --workspace` → 440 passed /
1 skipped；`cargo test -p daemon --test flow_delivery` → 33 passed。

**留给接卡人的真问题**（不是"修红测"，红已经没了）

`status()` 从纯查询变成了**带副作用**的接口——手机在等待循环里高频调它。
两个方向，验收人裁决：

1. **接受现状**，但把「`active` + 无任务 = 需要重拉」这条判据的**前提**写进
   代码注释与卡面：它成立的唯一理由是"没有任何东西会故意制造这个状态"。
   并在 `flow.suspend` 的 daemon 实现处加一条反向提示：要把它接到产品上之前，
   必须先解决这个歧义。
2. **让两种状态可区分**，把重拉挪出 `status()`：改成 daemon 启动时扫一遍
   active grant——与 NET-15 卡面写的"daemon 重启"场景严格对齐，`status()` 回到
   纯查询。这条更干净，但要动 NET-15 刚验收完的实现。

## 更正记录（2026-09-17，本卡开出后当天自查更正）

本卡初版把严重度写成「高」，并断言「手机在等待循环里持续调 `status()`，
用户点暂停后下一次轮询就会把传输自动恢复，暂停在产品上失效」。

**那条断言是错的，已删。** 我当时只读了 daemon 侧的状态语义，**没查
`flow.suspend` 有没有调用方**就下了产品级结论。查完发现它零调用、手机暂停走
`cancel`，所以"暂停被自动恢复"这件事今天不可能发生。

二分与根因分析本身是对的（确定性失败、提交定位、状态歧义都成立），错的是
从"存在歧义"直接跳到"产品已坏"。留作教训：**涉及产品影响的判断，必须先把
调用链走通**。
