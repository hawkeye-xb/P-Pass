# DEV-01 重配对识别与合并　级别 L2（2026-08-11 用户拍板 A 档：安全优先，合并方案定稿）

## 背景（用户痛点：重装后旧设备变僵尸行）

事实链：设备身份 = ed25519 密钥对（identity.key，app 沙盒文件）；
**同签名覆盖安装不丢身份**（多次实证，REL-02 通道跑起来后日常更新
不再有此痛）；丢身份只发生在卸载重装/清数据 → 新 NodeId = 新设备，
daemon 端旧行变「还没备份过」僵尸。
用户约束（二轮确认）：不做账号体系；**系统云备份方案已否决**（国行机
无 GMS 基本用不上，不为它开 allowBackup）——卸载重装仍需重扫一次码，
本卡的目标是让这一次重扫**无痛且不留僵尸**。

## 两段修法（按序交付，每段独立 commit）

### ① 配对请求带指纹提示

pair.request 加可选字段 `device_hint` = SHA-256(Build.MODEL +
ANDROID_ID) 前 8 字节 hex。要点（用户问过的，写死在这）：
- **不进二维码**——hint 在手机→daemon 的 pair.request 消息里，QR
  内容零变化（~120 字符维持）；
- **免权限**：Build.MODEL / ANDROID_ID 都无需任何运行时权限、零弹窗；
  ANDROID_ID 自 API 26 按「签名+用户+设备」隔离，同签名重装不变、
  仅恢复出厂重置——正是需要的性质。隐私披露进 README 隐私节一句话；
- **只作提示不作凭据**：鉴权语义零变化，authz 不读 hint；
- Android 设置页加开关「重装识别」（默认开）；关掉 = 不发 hint，
  行为回到现状（重装后出新设备行）。
- proto 演进按铁律：旧帧字节不变（无 hint 的旧客户端照常配对），
  金样本随行。daemon 存 hint（device 表加列，storage migration）。

### ② 允许时识别旧设备 → 合并（交互定稿，不要走样）

**手机侧流程零变化**（扫码→等待，不输入任何东西）。变化只在
**桌面端本来就要点的允许对话框**：daemon 发现存量设备同 hint →
对话框多一组选项，**默认选中「替换旧的 <名字>」**（继承名字、备份
记录、水位），另一项「作为新设备添加」= 与现状完全一致的全新流程
（测试全新授权、或用户就想当新设备，走这条）。点击数与今天相同。

合并语义：
- asset 的 src_device 归属迁移到新 NodeId（或映射表，方案自选写理由）；
- backup_watermark 合并取 max；旧设备行删除；审计 `device.merged`
  （from/to 双 NodeId 入 detail）；
- 合并也必须人工确认（「绝不默认放行」原则不破，默认选中≠自动执行）。

## 不准动

authz 鉴权语义（hint 绝不参与授权判定）；identity.key 格式与位置；
QR 内容；手机端配对流程步骤数。

## 可执行验收

1. ①金样本：新旧帧互解；无 hint 旧客户端配对不受影响（集成测试）；
   hint 开关关闭时 pair.request 不含该字段（贴帧对照）。
2. ②集成测试：旧设备在案 + 同 hint 新配对 → 选「替换」后 asset
   归属/水位/审计正确、旧行消失；选「新设备」路径旧行原样。
3. 反证：合并后用旧 NodeId 发 hello → 必须被拒（旧身份已删，贴输出）。
4. 全量测试绿 + arch-check 绿。

## 收尾

CI 绿；PROGRESS/NEXT 一行；ROADMAP 状态行；卡移 done/。

---
## 验收记录（2026-08-11 Salamira）

**段①金样本**：`crates/proto` `pair_request_hint_roundtrip`（带 hint 帧往返一致 + 序列化含键）+ `pair_request_old_frame_parses_as_none`（旧帧无 hint 键解析 None + 重序列化不含键——字节不变）✓；Kotlin `explicitNulls=false` 保证 null 不进帧（同性质）。
**段②集成**：`pairing_flow.rs` 3 个新测试——
- `reinstall_merge_replaces_old_device_keeps_assets_watermark`：旧设备+2 资产+水位 500 → 新配对 AcceptMerge → 资产归新 NodeId、水位=500、旧行消失、审计 device.merged ✓
- `reinstall_accept_as_new_keeps_old_row_untouched`：同 hint 但 Accept → 新旧两行并存、无 merge 审计 ✓
- `merged_old_identity_hello_is_denied`：合并后旧 NodeId `backup.begin` → NOT_AUTHORIZED ✓（hello 对未配对本就允许，反证用 member-gated 方法）
**storage 单测**：`find_by_hint_matches_active_only_and_excludes_self`（排除自身+revoked）+ `merge_moves_assets_takes_max_watermark_and_removes_old` ✓
**全量**：`cargo test -p daemon -p storage -p proto` 全绿（daemon 10 个测试文件全过；storage 27+13+17；proto 含金样本）。cargo fmt 干净。
**Android**：设置页「重装识别」开关（默认开）+ ReinstallHintPrefs 落盘 + pairWithQr 读开关传 hint；strings.xml en/zh 双语。assembleDebug 绿（JAVA_HOME=/opt/homebrew/opt/openjdk@17——默认 JDK 26 的 jlink 在 AGP 下失败）。
**挂账（验收人）**：真机重装→重扫→确认框默认「替换旧的」→旧行消失备份记录还在；开关关闭→重装后出新设备行。
