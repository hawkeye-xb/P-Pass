# DEV-02 删掉「替换旧身份」整条路径与设备指纹——一个密钥 = 一台设备，永不物理删

状态：🟥 挂号（2026-09-18 口径重写，见「口径变更」）
级别：L2（删代码 + 一次 schema 迁移；无新功能、无新状态）
关联: 撤回 [DEV-01](done/DEV-01-identity-survival-and-merge.md) 的合并与指纹机制 ·
延续 [DEV-01b](done/DEV-01b-hide-merge-entry.md) 已拍板的「重装 = 全新授权」 ·
与 [IDX-01](done/IDX-01-index-rebuild-has-no-runtime-entry-point.md) 互相放大 ·
邻居 [MOB-64](MOB-64-revoked-device-gets-no-feedback-until-next-attempt.md)（同一事实的手机侧反馈）

## 口径变更（2026-09-18，验收人拍板）

本卡初版的结论是「把物理删改成软删 + 加一列 `merged_into` + 设备详情里挂历史身份」。
**这个方向已被推翻**，原因是验收人先定了更上游的一条：

> **设备与身份 1:1。** 一对密钥 = 一台设备。

这条一旦成立，「替换旧身份」就**不可能存在**——续旧账目的定义就是"两个身份共享
一份账"，当场破 1:1。所以本卡不再是"把删改成标记"，而是：

**删掉整条替换路径，连带删掉为它服务的设备指纹。**

同时验收人对指纹本身的判断（原话意思）：指纹是手机自报的，别人能模拟，不要。
量级要说准——见「指纹的真实风险量级」一节，它不是可被远程利用的漏洞，删它的
**主要理由是替换路径一删它就没有任何消费者**。

## 问题

**一、唯一的物理删除点**

`crates/storage/src/device_repo.rs` 的 `merge_device()`（DEV-01「替换旧的」路径）
把 `asset.src_device` 改挂到新身份、取两边备份水位的最大值之后，执行：

```rust
sqlx::query("DELETE FROM backup_watermark WHERE node_id = ?")   // :219
sqlx::query("DELETE FROM device WHERE node_id = ?")             // :224
```

**两条都是物理删。** 卡面初版只写了设备行，备份水位那条一起算在本卡范围内。
删完之后旧身份在 `devices.list`、设备页、活动/审计投影里全部查无此人，只能翻
append-only 审计流考古。

验收人拍板（2026-09-17 原话）：「本地的数据只能通过本地删。如果移动设备在远端
解除绑定之后，我们本地接收到信息，可以把它标记为已断开授权，或者没接收到信息
也行，但本地不应该把这个设备的记录删除掉。」

补充原则（2026-09-18）：**任何设备都不应该对其它设备的记录有影响，尤其是删除。**
现状违背这一条——发起配对的是新设备，被删的是**另一行**。

**二、这条路当前潜伏，但离活只有一行**

- 桌面端入口的门是一个**硬编码常量**：`apps/desktop/src/App.svelte:186`
  `const MERGE_ENTRY_ENABLED = false;`。不是用户开关，把 `false` 改成 `true`
  缺陷立刻活。
- 手机侧 DEV-01b 只删掉了设置页那行 UI；`device_hint` **照发照存**
  （`ReinstallHintPrefs` 默认 `true`，见 `MainActivity.kt:589` 的注释原话
  「device_hint 照发照存…默认开，数据继续积累，未来打开入口即用」）。
- daemon 侧 `find_by_hint` 照常匹配、`hint_match` 照常回给桌面端
  （`crates/daemon/src/pairing.rs:196`）。

即：**一个没有任何消费者的设备标识符，正在被持续收集并落库。**

**三、指纹认不出它声称能认出的那件事**

`apps/android/app/src/main/java/com/hawkeyexb/ppass/transport/PairFlow.kt:22`：
`SHA-256(Build.MODEL + ANDROID_ID)` 前 8 字节。ANDROID_ID 自 API 26 按
「签名 + 用户 + 设备」隔离——同签名**重装/清数据不变**，但**恢复出厂会变**。
所以它的覆盖面比"这台像是原来那部手机"听起来窄。

## 指纹的真实风险量级（不要写高，也不要写成零）

伪造指纹**拿不到任何数据**：`merge` 的执行前置是①对方先拿到一次性配对码、
②机主点「允许」、③机主**另外**点了「替换旧的」。daemon 注释自己写着
"Hint is a hint only: no match = plain join"，authz 从不读它。

它的真实性质是**社工放大器**：伪造一个别人的指纹，机主的确认框就会替攻击者
说话——`App.svelte:1683` 那句「这台手机重装过——可以替换原来的「妈妈的手机」，
保留它的备份记录」。本该帮机主判断的提示变成诱导他点头的话术，而最后动手的是
机主自己。

**但删它的主要理由不是这个，是 1:1 定下之后它没有消费者。**

## 期望行为

清完之后语义收敛成一句话：

- **一对密钥 = 一台设备**，`device` 表按 NodeId 建行，**永不物理删**；
- 手机解绑 / 桌面移除 = `revoked = 1`（软删）+ 审计事件，行留在库里；
- **同一个 NodeId 回来 = 同一行复用**，备份水位在，照片不重传；恢复信任只有
  配对流程有权做（`unrevoke`，`upsert_device` 故意不清标记）；
- **重装 = 新密钥 = 新设备行**，旧行标「已断开授权」躺着，账目不续；
- 配对流程**无权写任何其它设备的行**——跨设备写的代码路径不再存在。

要认下来的代价（验收人已认）：重装后进度从零开始重算，手机会把范围内照片
重新扫、重新算哈希、重新报一遍。**照片不会重复存、字节不重传**（桌面端按内容
哈希去重），但首页「xx/xxx 张已回家」会从 0 爬，且重新哈希耗时耗电。重装是
低频事件，不值得为它引入"设备/身份两层"抽象。

## 范围

**只准动（全部是删）**

| 层 | 要删的东西 |
|---|---|
| storage | `merge_device()`（连两条 DELETE）、`find_by_hint()`、`Device.device_hint` 字段、`device.device_hint` 列（迁移） |
| daemon | `pairing.rs` 的 `HintMatch` / `hint_match` / `merge_from` 分支与那条 `device.merged` 写入、`ipc.rs` 的 `merge_node_id` 入参与透传 |
| proto | `PairRequest.device_hint` 字段 + 对应 roundtrip 测试 |
| android | `ReinstallHintPrefs.kt`（整个文件）、`PairFlow.kt` 的指纹计算与 `reinstallHintEnabled` 入参、`Proto.kt` 字段、`MainActivity.kt` 的传参 |
| desktop | `MERGE_ENTRY_ENABLED`、两处 `item.hint_match` 分支、`confirmPair` 的 `mergeNodeId` 参数与 `merge_node_id` 载荷 |
| tools | `testclient` 里的 `device_hint` 构造 |

**不准动**

- `revoke()` / `unrevoke()` / `upsert_device` 的既有软删语义——已经是对的
  （`pairing_flow.rs:270` 有断言 `"device row must be revoked after unpair"`）；
- 审计流里已经写下的历史 `device.merged` 事件与它的桌面端投影
  （`auditProjection.js:67`）——**历史不改写**，只是以后不再产生新的；
- `revoked` 这个布尔位要不要拆成「我移除的 / 对方解绑的」= MOB-64 的范围，不在本卡。

## 阻塞与依赖

无。DEV-01b 已经把入口关了一个多月，删它不改变任何用户可见行为。

**线路兼容已核实**：`crates/proto/src/msgs.rs` 没有 `deny_unknown_fields`，
serde 默认忽略未知字段。所以删掉 `device_hint` 之后，**老版本手机仍在发这个字段
也只会被静默忽略**，配对不会失败。这是本卡唯一一处线路风险，已排除。

## 验收标准

- [ ] RED 先行（门禁，不是行为测试）：加一条源码/schema 门禁——`crates/storage`
      内不允许出现 `DELETE FROM device`，命中即失败。删代码前这道门必须真红
      （现在 `device_repo.rs:224` 就命中）。**这是本卡唯一的长期资产**：
      语义靠人记会再漏，靠门禁才不会。
- [ ] 同一道门禁覆盖 `DELETE FROM backup_watermark`（或说明为什么它可以删）。
- [ ] GREEN：上表「只准动」全部删净；`rg -i 'device_hint|hint_match|merge_device|merge_node_id|MERGE_ENTRY'` 在
      非测试、非审计历史的源码里零命中。
- [ ] 迁移：新增 migration 删掉 `device.device_hint` 列（已收集的指纹随列一起
      消失 = 顺手清掉了不该留的数据）。迁移在**已有数据的库**上跑通，不是只在
      空库上。
- [ ] 回归（证明"不删"的那条语义没被顺手改坏）：`pairing_flow.rs` 的解绑→
      `revoked=1`、移除→`revoked=1`、**同 NodeId 重新配对→`unrevoke` 复用同一行**
      三条断言全绿。第三条如果现在没有，本卡补上——它是 1:1 语义的正面证据。
- [ ] 全量：`cargo nextest run --workspace` + Android JVM 全量（报计数）+ `just ci`。
- [ ] 真机：三星 SM-S9210 走一遍「解绑 → 重新扫码」，确认桌面端确认框**不再出现**
      任何「替换旧的」相关文案，设备页旧行仍在（标已断开授权），新行正常出现。

## 实施记录

- 2026-09-17：排查 IDX-01「10 张照片不在列表」时读 `device_repo.rs` 撞见物理删。
  **本次照片丢失不是它造成的**（IDX-01 卡里已列反证），它是独立的同类缺陷。
- 2026-09-18：与验收人重新讨论后**口径整体重写**（见「口径变更」）。初版方向
  （软删 + `merged_into` + 设备详情挂历史身份）作废，理由：它是为"设备与身份
  两层"服务的设计，而验收人先定了 1:1。同时核实了四件事实：桌面入口是硬编码
  常量而非用户开关；手机侧指纹仍在照发照存；指纹恢复出厂会变、覆盖面比声称的窄；
  proto 无 `deny_unknown_fields` 故删字段线路安全。

## 备注

- 与 IDX-01 的放大关系仍成立：`rebuild()` 从目录名反推 `src_device`，只要
  `merge_device` 还在，重建之后必然产出一批 `device` 表里查无此人的资产。删掉
  它同时也拆掉了这个放大器。
- 卡片文件名沿用旧名（`...-must-not-be-hard-deleted-on-merge.md`），因为
  `docs/QUEUE.md:111` 与 issue #136 都按这个路径链接，而 QUEUE.md 已冻结只读。
  文件名比内容旧一步，不改。
