# NEXT — 当前状态与下一步（2026-08-04，H-10c 收官后）

> 交接件，随每次收口更新。历史结论已并入 ROADMAP/PROGRESS。

## 一、H-10c：✅ 端到端 PASS（v0.2.0-test.6，run 30873612775）

迭代记录：test.4 ❌（bundle-desktop-macos.sh 缺执行位）→ test.5 ❌（dmg 不在
artifact 根布局）→ **test.6 全绿**。两个修复直接进 main（5020136、2464dcd）。

| 平台 | 资产 | 状态 |
|---|---|---|
| macOS | ppass-macos-arm64.zip（自包含 daemon）+ **P-Pass.app + dmg** | ✅ Codesign skipped（H-02 未接，Gatekeeper 提示右键可过）|
| Android | **签名版 APK**（CN=HawkeyeXbOrg） | ✅ keystore 门控走真分支，secrets 在位实锤 |
| Windows | daemon.exe / testclient.exe（未签名，H-02 范畴） | ✅ |

## 二、立即可做：H-10b 用户实测（无脑用户走查）

1. GitHub Releases → `v0.2.0-test.6`（draft，需登录）→ 下载 dmg 和 apk
2. Mac：装 dmg → 首次打开右键→打开（Gatekeeper）→ 三步向导 → 出配对 QR
3. 手机：装 apk（允许"未知来源"）→ 扫码 → 首次备份
4. **每个卡点/看不懂的提示记下来**，丢回主会话，逐条立卡——这就是 H-10b 的产出

## 三、待派卡

- **H-10a 重派**（L1，云端 agent）：quickstart 对着 test.6 的真实资产改写
  （dmg/apk 下载步骤、Gatekeeper/未知来源提示、截图占位），验收 = 文档里每个
  资产名与 test.6 draft 逐字一致 + 不承诺不存在的东西。
- **H-02**（L3，需用户本人）：Apple Developer 证书导出 p12（钥匙串交互授权，
  agent 代替不了）→ 配 APPLE_* secrets → 打 tag 验证 Codesign/Notarize 走真分支。
  完成后 macOS 侧免右键直开。
- 挂账不变：T-070b disk_full CI 反证、H-07 relay 正式试点、鸿蒙重扫码。

## 四、发布链路（H-10b 顺利后）

家人手机装签名 APK + 媳妇 Mac 换新 bundle → **全家狗粮周（M2 gate）开跑**；
狗粮周 + H-02 齐了 → 正式 `v0.2.0`。
