# NEXT — 当前状态与下一步（2026-08-04，H-10c 收官后）

> 交接件，随每次收口更新。历史结论已并入 ROADMAP/PROGRESS。

## 〇、重要更新（2026-08-04 午后）：test.6 的 APK 是残包，用 test.7

test.6 的签名 APK 缺 libiroh_ffi.so（根 .gitignore 全局 *.so 把它挡在 git 外，
只有验收人本机工作区有此文件——任何干净克隆构建的 APK 都装上即崩）。
修复 44225c1：.so 入库 + pr.yml/release.yml 各加打包完整性断言
（unzip -l 确认 .so 在 APK 里，缺失即红）。**v0.2.0-test.7 全绿且断言
step success——下载 APK 请用 test.7**，与残包同签名可直接覆盖安装。

## 一、H-10c：✅ 端到端 PASS（v0.2.0-test.7，run 30877876487）

迭代记录：test.4 ❌（bundle-desktop-macos.sh 缺执行位）→ test.5 ❌（dmg 不在
artifact 根布局）→ **test.6 全绿**。两个修复直接进 main（5020136、2464dcd）。

| 平台 | 资产 | 状态 |
|---|---|---|
| macOS | ppass-macos-arm64.zip（自包含 daemon）+ **P-Pass.app + dmg** | ✅ Codesign skipped（H-02 未接，Gatekeeper 提示右键可过）|
| Android | **签名版 APK**（CN=HawkeyeXbOrg） | ✅ keystore 门控走真分支，secrets 在位实锤 |
| Windows | daemon.exe / testclient.exe（未签名，H-02 范畴） | ✅ |

## 二、立即可做：H-10b 用户实测（无脑用户走查）

1. GitHub Releases → `v0.2.0-test.7`（draft，需登录）→ 下载 dmg 和 apk
2. Mac：装 dmg → 首次打开右键→打开（Gatekeeper）→ 三步向导 → 出配对 QR
3. 手机：装 apk（允许"未知来源"）→ 扫码 → 首次备份
4. **每个卡点/看不懂的提示记下来**，丢回主会话，逐条立卡——这就是 H-10b 的产出

## 三、待派卡（2026-08-04 晚更新，按模板可直接转发）

### → 运维 agent

```
## OPS-01 workers 生产部署  级别 L3
目标：telemetry + rendezvous 两个 CF worker 真实部署（裁决：走 CF，不用
  PostHog——客户端线格式已对齐自建 worker，且守 self-hostable 人设），
  狗粮周"备份完成率"可度量。
步骤：① CF 账号 wrangler deploy 两个 worker（生产配置进私有仓 ppf-ops，
  公开仓只有占位）；② telemetry 绑 Analytics Engine dataset
  ppass_telemetry；③ 域名路由 telemetry.p-pass.hawkeye-xb.com 与
  rendezvous 域名解析到位；④ curl 验证：telemetry 合法批 200 / 非法 400 /
  错路径 404；rendezvous 健康 200；⑤ 从一台真设备发一条真实遥测，用 AE
  SQL API 查回来贴原文。
可执行验收：④ 四个响应码 + ⑤ 查询结果原文。
硬约束：不在中国大陆运营端点（CF 默认网络合规）；凭据不进公开仓。
收尾：部署记录进 ppf-ops；本文件状态行更新。
```

### → 云端 agent

```
## UPD-01 自更新通道闭环  级别 L2
目标：改代码→tag→设备收到更新提示。桌面走 tauri-plugin-updater 标准库，
  Android 自研轻实现（脱店 App 无标准库，第三方多失修；系统 PackageInstaller
  强制同签名校验兜底），daemon 自更新按用户裁决搁置（App 带着 sidecar 走）。
范围：release.yml（manifest 产出+签名+上传为 release 资产）、apps/desktop
  （tauri-plugin-updater，公钥入 tauri.conf）、apps/android（打开时检查
  manifest → 提示 → 下载 → PackageInstaller）、update.rs（真钥替换全零占位
  + 补"可解析成 VerifyingKey"测试）。
前置（用户本人）：生成 Ed25519 密钥对——私钥进 GitHub secret
  UPDATE_SIGNING_KEY，公钥进代码。生成命令写进 PR 描述，不许 agent 代生成。
可执行验收：test tag → 资产含签名 manifest.json；nextest update 全绿；
  反证：篡改 manifest 一字节客户端必拒（贴输出）。真机"收到提示"归用户验收。
不准动：现有资产命名与产出路径。
收尾：走 PR 等 review；ROADMAP/PROGRESS 各一行。
```

```
## E2E-01 live 剧本进 CI  级别 L1
目标：android-hello/pair/backup 三剧本进 CI，防协议回归。
运行时机（规定）：必须跑 = nightly 定时 + 每个 release tag（产物构建前门禁）；
  选择性 = PR 打 e2e label 或手动 dispatch；每 commit 不跑（预估 8-15 分钟）。
范围：新建 .github/workflows/e2e.yml；tools/android-*.sh 最小适配。
已知坑（逐个修，各附证据）：ubuntu 装 libheif/ffmpeg（抄 scenarios job）；
  确认 iroh Maven jar 含 linux-x86-64 natives；PPF_BIND_ADDR=127.0.0.1:0；
  gradle 只跑 JVM 测试所需的最小 SDK。
可执行验收：dispatch 一次全绿，HELLO OK / PAIR OK / BACKUP OK 12/12 见于
  日志；反证：分支上临时改坏 hello 响应 → job 必红（不进 main）。
收尾：走 PR 等 review。
```

```
## REL-01 版本与发布规范  级别 L0
目标：trunk-based 流程成文：main 永远可发布；tag=release（SemVer）；hotfix
  才开 release/vX.Y 分支；draft→人工 publish；每 release 前 bump+changelog。
范围：docs/RELEASING.md（en 主+zh）+ CHANGELOG.md 初始化（keep-a-changelog）
  + tools/bump-version.sh（Cargo.toml workspace version 与 android
  versionName/versionCode 同步）。
可执行验收：照 RELEASING.md dry-run 一遍每条命令可执行；bump 脚本跑完
  git diff 恰好只改版本号行。
收尾：走 PR 等 review。
```

- **H-10a-fix**（L0，云端 agent）：已单独发出（quickstart 对齐 test.7 资产，
  Windows 段改诚实版）。
- **H-02**（用户本人）：逐步操作单见 `docs/runbook/h02-apple-signing.md`。
- 挂账：T-070b disk_full CI 反证（可并入 E2E-01）、H-07 relay 正式化、
  设备表旧三星身份清理（桌面 App 设备列表点移除）。

## 四、发布链路（H-10b 核心已验证 2026-08-04）

签名 APK + dmg 的完整用户旅程已由用户本人走通（下载→安装→扫码→配对→
自动备份 23→48→时间线）；鸿蒙也已重配对。下一步：家人手机装 APK +
媳妇 Mac 换 dmg → **全家狗粮周（M2 gate）**；狗粮周 + H-02 + UPD-01 齐了
→ 正式 `v0.2.0`。
