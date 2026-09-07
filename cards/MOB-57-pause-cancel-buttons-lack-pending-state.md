# MOB-57 暂停/取消按钮连点会排队多次命令，无处理中反馈（L1）

> 🟢 状态：代码已合并，本地验证通过 · 当前节点：等真机复核 ·
> 下一步：真机确认连点不再排队、按钮有禁用/处理中反馈 · 协同分支：`main`
> 级别：**L1**（UI 反馈缺失导致用户误判"卡死"，连点还会让命令排队执行）
> 阻塞：无

## 问题

2026-09-07 真机黑盒回归反馈：
- "点击'暂停'反应比较迟钝"
- "点击'取消当前轮'没有任何反应，然后再点击'继续'的时候就不会再触发
  备份了" ——按钮连点几次后表现为卡死

根因（源码核实，`HomeScreen.kt`/`BackupUiStateHolder.kt`）：
`HeroSecondaryButton` 的 `onClick` 直接调用 `holder.backupNow()` /
`holder.cancelCurrentRound()`，两者都是把命令丢进协程后立刻返回，UI 状态
要等下一次 500ms 轮询 tick 才会刷新——这个窗口期间按钮没有任何禁用/
处理中视觉反馈，用户看不出点击有没有生效，于是接着点，多次点击各自排进
协程队列依次执行，表现为"按钮卡死""连点后失效"。

## 修复范围（本卡边界）

只修"命令处理中应禁用按钮 + 显示处理中文案"这一个真实 UI 缺陷。

**不在本卡范围内**（已有明确设计，不是 bug）：MOB-49 卡已裁决「取消当前
轮」是终态放弃（`CANCELLED_BY_USER_ROUND`），不新增自动恢复/确认逻辑——
"取消轮的照片如何恢复传输"没有核心逻辑要补，这是既定产品语义。

## 验收标准

- [x] `BackupUiStateHolder` 新增 `commandPending` 状态，`backupNow()`/
      `cancelCurrentRound()` 命令执行期间为 true，命令未完成时重入调用
      直接丢弃（不排队）
- [x] `HomeScreen` 的暂停/继续/取消按钮据此禁用 + 换"处理中…"文案
- [x] 全量 JVM 测试无回归（288/0/4）
- [ ] 真机验证：连续快速点击暂停/取消按钮，确认命令不重复排队、按钮有
      禁用视觉反馈

## 实施记录

- `BackupUiStateHolder.kt`：新增 `_commandPending` state；`backupNow()`/
  `cancelCurrentRound()` 用 `if (_commandPending.value) return` 做重入
  守卫，`finally` 块里复位
- `HomeScreen.kt`：`HeroSecondaryButton` 加 `enabled` 参数（未启用时降低
  边框/文字透明度）；暂停/继续/取消按钮据 `commandPending` 禁用并换文案
- `MainActivity.kt`：`commandPending = holder.commandPending.value` 接线
- `strings.xml`（en + zh）：新增 `backup_command_processing`
