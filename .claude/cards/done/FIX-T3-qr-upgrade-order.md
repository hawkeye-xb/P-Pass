# FIX-T3 配对码升级顺序地雷　级别 L0

## 事实（2026-08-10 验收人 review 实锤）

旧 APK（≤0.3.0-test.2）的 `parsePairingQr` 只从 `a=` 参数取 daemon 地址；
H-10b-QR 之后桌面端新 QR 只带 `r=`（relay）。**旧手机 App 扫新码 →
addr=null → 拨不出去，配对静默失败**。当时只验证了「新 App 读旧码」，
反方向没人测。旧 APK 无法追改，只能修前向 + 把话说清。

## 修法

1. 桌面配对弹窗 QR 下加一行小字：「手机 App 需 v0.3.1 或更新」（i18n
   en/zh 双语，走 assets/i18n 字典，别写死在组件里）。
2. Android 解析器加防御：`a=`/`r=` 都缺时给人话错误（「配对码无法解析，
   请把电脑端和手机 App 都升级到最新版」），不再静默失败。
3. CHANGELOG + 下次 Release notes 写明升级顺序：**先升手机 App，再扫新码**。

## 可执行验收

1. 单测：缺地址参数的 QR 串 → 人话错误（非崩溃、非静默）。
2. 桌面弹窗文案截图（模拟器/真窗口皆可）。
3. i18n 对称测试绿（en/zh 键集一致）。

## 反证

给解析器喂 `ppf://pair?node=..&t=..`（无 a=/r=）→ 修复前静默、修复后
人话错误（贴对照输出）。

## 收尾

直推 main 前确认 CI 绿；PROGRESS/NEXT 各留一行；卡移 done/ 并附验收记录。

---
✅ **验收记录（2026-08-10，Salamira）**：
- ①桌面弹窗：App.svelte QR 弹窗（qr-lg 下）新增小字
  `{t("ui.qr_phone_version")}`——新 i18n key `ui.qr_phone_version`
  （en: "Phone app must be v0.3.1 or newer to scan this code" / zh:
  "手机 App 需 v0.3.1 或更新才能扫这个码"），四份 JSON 同步（根
  en/zh + Android 副本），keys.rs 注册（ALL 65→66，len 断言同步）。
- ②Android 防御：PairFlow.kt 缺地址分支文案改为「配对码无法解析，
  请把电脑端和手机 App 都升级到最新版」（原「配对码缺少地址信息」），
  非崩溃非静默（该分支原本就存在，本卡把话说清+补测试钉住）。
- ③CHANGELOG [Unreleased] Fixed 段记录升级顺序：先升手机 App 再扫新码。
- 验收①单测：`qrWithoutAnyAddressIsDetectable`（PeerAddrTokenTest）——
  无 a= 无 r= 的码 → addr=null 且 relayUrl=null（上层 PairFlow 据此给
  人话错误，非静默）。android 全量 **100/100**（99+1）绿（含 i18n
  对称测试 StringsSymmetryTest 零漂移断言）。
- 验收②桌面弹窗截图：本地无真窗口（模拟器/真窗口归验收人补跑）。
- diag 8/8 绿（keys 注册 + len 66）+ desktop vite build 绿。
- 反证：喂 `ppf://pair?node=..&t=..`（无 a=/r=）→ parsePairingQr
  返回双 null（测试断言），PairFlow 返回人话错误——修复前该分支文案
  模糊（不引导升级），修复后明确。贴测试输出在案。
