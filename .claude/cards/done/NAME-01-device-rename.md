# NAME-01 设备改名　级别 L0　【队尾，可砍】

decisions ②：ID 与显示名分离。daemon 加 `device.rename`（IPC，owner
本机操作；audit 记 device.renamed 旧名→新名+node_id）；桌面设备行改名
入口（点名字编辑）。审计/水位/一切逻辑仍按 node_id，显示层才用名字。

验收：改名后 devices.list 新名、audit 有记录、重启不丢；集成测试 +
反证（audit 断言删掉必红）。收尾照旧。

---

## 验收记录（2026-08-12 Salamira）

**实现**（decisions ②：ID 与显示名分离，一切逻辑仍按 node_id）：
- storage `rename_device(node_id, new_name) -> Result<Option<String>>`：
  先取旧名（audit 用）→ UPDATE name；未知设备 = None。
- daemon IPC `device.rename`（owner 本机操作，与 device.revoke 同鉴权
  面）：必填 node_id + name（trim、非空、≤64 字符）；审计
  `device.renamed`（detail = 旧名 -> 新名 (node_id)）；IPC-02
  DEVICE_CHANGED 事件即时刷新；未知设备 NOT_FOUND。
- 桌面设备页：设备名变按钮（hover 下划线）→ 点击变输入框 → 回车/失焦
  保存、Esc 取消、空名/未改动不提交；纸底墨字 token 化。
- i18n：ui.rename / ui.rename_saved / ui.rename_failed 三 key
  （keys.rs 常量 + ALL + en/zh 字典 + Android 捆绑副本同步）。

**验证**：
- storage `rename_updates_name_and_returns_old`（改名返回旧名、list 新
  名、ID 不变、未知设备 None）+ 既有 9 项全绿。
- daemon 集成 `device_rename_updates_list_and_appends_audit`（改名 →
  list 新名 + audit device.renamed 含旧名→新名+node_id）+
  `device_rename_rejects_bad_input_and_unknown_device`（空名/缺参/未知
  设备 NOT_FOUND）；ipc_flow 13/13 绿。
- diag 8/8（ALL 长度断言 76→79 已同步）；android StringsSymmetry 绿；
  vite build 绿；fmt/clippy 干净。

**反证**：audit 断言删掉必红（device_renamed.len()==1 锁死）；改名不改
node_id 有断言锁死（decisions ② 一切逻辑仍按 ID）。

**挂账（真机）**：桌面点设备名改名 → 列表即时出新名 + 活动流看到
device.renamed；重启 daemon 后名字保留。
