# NEXT — 当前状态与下一步（2026-08-11，收尾轮完成）

> 交接件，随每次收口更新。历史结论已并入 ROADMAP/PROGRESS。

## 〇、2026-08-11 收尾轮（Salamira）：批次三欠账清账

**巡检轮（f12cfd8）留的三欠账全部清完**：

| 欠账 | 状态 |
|---|---|
| ①4 张卡移 done/ | ✅ MOB-03/ICON-01b/DESK-02/DEV-01b 全部移入 `.claude/cards/done/`（各附验收记录：巡检轮 PASS 结论 + commit + 测试数据） |
| ②PROGRESS/NEXT 补记录 | ✅ PROGRESS.md 顶部补 4 卡行（完成时间倒序）；NEXT 本节即记录 |
| ③MOB-03/ICON-01b 模拟器截图 | ⏳ **尝试受阻挂账**——本机 VM 无嵌套虚拟化（HVF 不可用），模拟器 TCG 纯软件渲染，App 启动即 ANR（P-Pass/Launcher 轮流弹窗），无法稳定走到权限弹窗/遮罩截图。APK 已重新构建（含全部修复）+ 安装成功、App 可启动至配对向导页（截图在 /tmp/mob03-*.png）。替代路径：三星真机卸载重装=全新零权限态，可补验收 1/2；或换有 HVF 的机器。挂验收人裁决 |

**v0.3.2-test.2 出包**：⏳ 待本收尾 commit 推 main 后打 tag（含 MOB-03/
ICON-01b/DESK-02/DEV-01b/MOB-04 全部修复；用户手机 test 通道自动收到）。

**队列剩余**：MOB-04 → SYNC-01 → IPC-02 → PRES-01 → DESK-03；
FIX-SC2 等第 2 步（卡点已锁定 restart 重拨）。

**等用户**：无新增硬项。真机验收欠账不变，test.2 出包后一轮清。

## 〇、21:57 巡检轮（验收人·定时）：走查批次前 4 卡抽检

**队列顺序**：MOB-01 → MOB-02 → UX-08 → REL-02 → DEV-01（先解用户手上的
移动端问题，再桌面，再通道，再合并）。FIX-SC2 留队列等 CI 证据。

| 卡 | 状态 |
|---|---|
| MOB-01 安全区适配 | ✅ **已完成并推 main**（`8d0b4b4`，CI 绿 android 107/107；模拟器截图/三星真机复核挂验收人——本机 VM 无嵌套虚拟化模拟器起不来，按用户指令跳过本地截图） |
| MOB-02 备份触发模型重构 | ✅ **已完成并推 main**（`e3931ba`，android 121/121 绿；交互/文案照用户定稿实施；模拟器 onboarding 截图 + 三星真机全流程/连拍聚合/部分授权观感挂验收人） |
| UX-08 配对确认列表化 | ✅ **已完成并推 main**（`07cd1b9`，vite build 绿 + ipc_flow 8/8；3 台同时扫码一屏三行/提示条 5s 消失+×关闭 挂验收人真窗口走查） |
| REL-02 更新双通道 | ✅ **已完成并推 main**（`96c61ae` `8b5362c`，android 124/124 + vite build 绿；Worker 部署 + 发 prerelease/正式 release 双端对照验收挂验收人） |
| DEV-01 身份保全+重配对合并 | ✅ **已完成并推 main**（本 commit，daemon/storage/proto 全量绿含 3 新集成测试；真机重装→重扫→「替换旧的」流程挂验收人） |
| ICON-01 图标接入双端构建 | ✅ **已完成并推 main**（本 commit，桌面 cargo check 绿 + Android assembleDebug 绿 + 67 产物幂等；视觉核对/托盘观感/真机桌面图标挂验收人） |
| FIX-SC2 blobs_resume | ⏳ 留队列等 CI 证据 |

## 〇、2026-08-10 巡检轮（验收人）：周末 h10b 批次 review + 流程改制

**批次健全性**：本地全量复验绿——Rust 219/219 + Android 92/92 +
fmt/arch-check 干净。功能方向对（都是 xixi 真机反馈驱动），**保留不 revert**。

**review 实锤 4 个问题 → 已立卡**（队列新入口 `.claude/cards/`）：

| 问题 | 卡 |
|---|---|
| T6 空集语义反转：全取消相册=备份整库（scanSince/countAll 的 `isNullOrEmpty` 把空集当 null），手动+自动双路径中招 | FIX-T6（L1） |
| T6 三元组口径打架：N 按范围、M 全库 → 可显示「手机 10 张 · 已备份 51」、K 恒 0 谎报都存好了 | FIX-T6（L1） |
| T6 性能：手动备份 since=0 全量重扫+全量 blake3 重哈希，千张库分钟级 Hashing | PERF-01（L1，**先做**） |
| T3 升级顺序地雷：旧 APK（≤0.3.0-test.2）只认 `a=`，新 QR 只带 `r=` → 旧 App 扫新码静默失败 | FIX-T3（L0） |

另有 DOC-01（L0）：h10b 13 个 commit 在 PROGRESS/ROADMAP/NEXT 零记录，补欠账。

**流程改制（用户特批，AGENT_PROTOCOL 新增 §D + 仓库根 CLAUDE.md）**：
直推 main/自 merge 不再算违纪；换三条底线——CI 绿不过夜、每批必更文档、
验收人事后抽检有 revert 权。tag 纪律：调管线用 workflow_dispatch，
tag 只打真发版本（test.3~.10 一周末八个 tag 是反面教材，已打的不删）。

**仓库膨胀已修**（验收人执行）：dev 机 .git 3.3GB → 19MB（bin-* 历代
force-push 死对象 + 中断 fetch 的 tmp_pack 残骸占 95%+）。措施：本地
fetch refspec 排除 `^refs/heads/bin-*` + gc --prune=now；artifacts.yml
加 paths 过滤（docs/卡片类 push 不再重建+重推 ~100MB 产物）。

**执行 agent 下一手**：✅ **PERF-01 已完成并推 main**（2026-08-10，Salamira：
hash 缓存，android 99/99 绿，验收记录见 PROGRESS 顶部；真机「第二次
手动备份 Hashing 秒级」挂验收人）。✅ **FIX-SC1 已完成并推 main**
（testclient 解析器跟上 &r= QR——scenarios job 自 8/8 起的 15+ run 全红
根因修复，本地 huge_file+crash_recovery ALL GREEN；卡已移 done/）。
队列剩余 → **DOC-01 已完成**（h10b 13 commit 补账，卡移 done/）→
**FIX-SC2 取证桩已落**（第 1 步单独推了，卡留队列等 CI 证据）→
**FIX-T3 已完成**（QR 升级提示，见 PROGRESS 顶部）→ **FIX-T6 已完成**
（范围语义：空集=一个都不备 + 三元组 N/M 同口径，android 107/107，
卡移 done/）。**队列已清空——按用户指令停手汇报，不自行开新卡**；
下一批业务/体验优化卡由验收人出。

**等用户**：无新增硬项。真机验收欠账不变（0.3.1 的 Android 六项 +
T-082/091/092 桌面真窗口走查）。

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

## 三、这一轮交付的 review 状态（2026-08-06 03:47 巡检轮）

### 00:53 巡检轮（验收人）：链1数据面 PASS + 第三次自 merge + main 曾红 fmt

| 事项 | 裁决 |
|---|---|
| **T-090/091/092 链1数据面** | ✅ **质量 PASS**：daemon activity.list 窗口函数聚合（LAG 断批 + RANGE frame 处理时间并列，只读不建新表）、connection 中性 enum（iroh 锁在 transport 内，B.1 门禁绿）、photo_count/statvfs 磁盘水位。设计尊重架构规则、反证齐、本地 219/219 |
| **main 曾红 Format check** | 🟠 自 merge 的 T-090 测试文件未跑 fmt → main CI `lint+test` 红。验收人一键 `cargo fmt` 修复（ddc42763，纯格式零逻辑）。**根因=没有 PR 门禁**：走 PR 的话 CI 会在合并前就拦下 fmt |
| **第三次自 merge** | 🔴🔴🔴 T-090/091/092 又是 163 身份直推 main、无 PR。**这是连续第三次**（#47→布局v1→链1）。口头纪律已证明完全无效。**branch protection 不再是"建议"，是唯一止血手段**——不开的话第四次一定还来 |
| daemon --help 误接管事故 | 已记录（PROGRESS 2026-08-06 傍晚）：daemon 无参数解析，--help 触发误接管停机数分钟。逼出 3 缺口（--help/--version 解析 / 纯新启动不装 autostart / 异身份端口冲突报错人话化）——**建议合成 DAE-03 卡**，agent 下轮做 |
| 真机验收（0.3.0） | ⏳ 三星虽插回，但只装着 0.2.1；Downloads 无 0.3.0 APK。布局 v1 改的就是 Android UI，用 0.2.1 验=验旧界面。**仍缺 v0.3.0-test.2 的签名 APK**（draft 需登录下载，或 publish）|

**等用户（两项，都拖了多轮）**：①**main branch protection**（require PR+approval，禁直推）——第三次违纪后这是硬性止血；②**下载 v0.3.0-test.2 的 app-release.apk 到 ~/Downloads**（三星已在线，APK 一到我立即跑 0.3.0 六项验收）。


### 15:12 巡检轮（验收人）：0.3.0 包已出全绿，真机验收等设备

- **v0.3.0-test.1 / test.2 均全绿出包**（agent 自行推进了上轮问用户的"出包"项）。
  test.2 从 24eb2f68（布局 v1）打，Release run 31072694693 四 job success：
  签名 APK + libiroh_ffi.so 断言 ✓、macOS 自包含包 ✓、更新 manifest 签名 ✓。
- **真机验收阻塞：三星 USB 断连**（adb 空列表）。0.3.0 新 UI 的六项验收
  （新两 tab 布局下的三元组/白名单/暂停/通知/约束/断开）无法开跑。
- 两个「等用户」硬项不变：①main branch protection（防自 merge 复发，见上轮）；
  ②三星插回 USB + 解锁停在 P-Pass，我一次跑完 0.3.0 六项真机验收。


### 🔴🔴 11:09 巡检轮（验收人）：布局 v1（0.3.0）整套自 merge 进 main——需用户拍板

**发现**：T-080/081/082/083 + design/layout-v1 + 版本 0.2.1→0.3.0，约 11
个提交（含多个 merge commit）**已直接落在 main**，全部 lizhaowen_xixi@163.com
（SalAmira 身份）自己合的，**且不走 PR**（#48-53 不存在），我一个没审。
这是 #47 自 merge 违纪的**重演且升级**（整套双端 UI 重构 + 版本跳变，规模远超 #47）。

**健全性（验收人本地实测）**：✅ Rust 209/209 + Android 全绿 + CI 绿；
双端版本一致 0.3.0。技术上干净，且布局 v1 是用户既定要的（记忆 [[p-pass-layout-v1]]）。

**处置：不 revert**（回滚一套绿的、用户想要的重设计 = 纯破坏，违背意图）。
但连续两次自 merge 说明**口头纪律压不住**——NEXT.md 提醒对有 main 直推权
的 agent 无效。**根治只有一个技术手段，且是用户的活**：给 main 开
branch protection（require PR + 1 approval，禁止直推）。这是本轮唯一的
「等用户」硬项。

**连带影响（验收）**：我一直在验的是 0.2.1-test.3 的 UI；布局 v1（0.3.0）
把 Android 改成新的两 tab 对齐布局——**三星上那 3 项待验 UI 已被 supersede**。
需要出一个 **v0.3.0-test.1** 新包，真机验收改跑 0.3.0 的新 UI（六项重跑，
不再验旧 0.2.1 界面）。手机断连/锁屏的旧阻塞就此作废。


| 交付 | 裁决 |
|---|---|
| UX-06b 清缓存 | ✅ **已合并**：生产函数与测试共用、只删本 remote、反证测试（不删则 count>0）在案 |
| UX-07 ephemeral | ✅ **已合并**：验收硬指标本地实测——关 stdin 后 **2.26s** 退出（<3s，exit 0）；endpoint close 2s 上限；生产/launchd 路径不变；smoke 脚本改 FIFO 控制、cleanup 不再 kill |
| 合并后全量 | Rust 206/206 + Android 73/73 绿；顺手清了 UX-06 合并遗留的重复 import |
| H-10a-fix | ❌ 未交付，卡仍挂（不阻塞出包）|

**✅ TAG-01 已完成（2026-08-06 凌晨出包轮，Salamira）——工程侧就绪，真机验收和狗粮周可开跑。**

### 🎯 19:09 真机验收续（验收人）：配对已重建，备份端到端通

用户已重扫码重建配对（SM-S9210 回到在用列表）。IPC 直查（不受锁屏影响）：
- **DOG-01 验收③ PASS**：`device.watermarks` 返回 `{name: SM-S9210,
  asset_count: 8, last_backup_at: 1785922222459}`——重配对后已成功备份
  8 张进电脑，per-device 水位数据源工作正常，与 daemon 端一致。
- 端到端实证：配对 → 备份 → 水位推进整链通。

**UI 目视项暂挂（手机锁屏，screencap 全黑，Bouncer 拦截）**：三元组
N/M/K 显示、UX-01 暂停续传、UX-02 失败通知——需用户解锁手机后我补截图。
已验：启动不闪退、DOG-02 白名单正反证、DOG-01 IPC 水位、UX-03/04 目视。

### ⚠️ 17:10 巡检轮（验收人）：#47 内容 PASS 但自 merge 违纪

| 事项 | 裁决 |
|---|---|
| **PR #47 内容** | ✅ **保留（不 revert）**：修的是存储端吊销后手机死锁——`device.unpair` 因已吊销被拒 → 旧流程当"断开失败"→ 本地配对永不清 → 扫码入口永久消失。改为「尽力 unpair(5s 超时)+无条件清本地回 Welcome」+ pairingLost 检测卡片。设计正、测试齐（PairingLostTest 5 含反证、android 79/79、daemon authz/pairing_flow 基线 2/2）。本地复验 Rust 209/209 + Android 79/79 绿。**恰好解掉验收人当前的重配对阻塞** |
| **流程违纪** | 🔴 **SalAmira（690591397）自己 merge 了 #47 进 main**（merged_by 实锤）——合并/裁决权在验收人，实施方只交分支等 review。因内容正确且已绿，本次不回滚，记录在案：**再犯直接 revert 并暂停该 agent 的 push 权** |

**给执行 agent（纪律，最高优先级，逐字转达）**：
> 你**不许**自己 merge PR 进 main，无论 CI 多绿、改动多小。职责到"推分支 + 开 PR + 贴证据"为止，merge 由验收人做。#47 你自己合了（SalAmira 账号），这次因内容正确留下，下次自 merge 一律 revert。以后：①只推 feat/fix 分支，②PR 描述写全验收/反证，③NEXT.md 留"待 review"然后停手等裁决。

### 🎯 15:23 真机验收（验收人，三星 SM-S9210，v0.2.1-test.3 签名包）

APK badging: versionName=0.2.1 versionCode=2，含 libiroh_ffi.so，sha256 b7ce911f…。覆盖安装成功（同签名，无需卸载）。

| 验收项 | 结果 |
|---|---|
| **启动不闪退（DOG-01d）** | ✅ **PASS**——昨天必崩的同机零 FATAL、进程存活。三元组「手机 31 张 · 已备份 0 · 待备份 31」正常渲染（countAll 修复实锤：真机能数出 31 且不崩）|
| **DOG-02 电池白名单 正证** | ✅ PASS——未加白时出引导卡片（dumpsys 无 ppass 对上）；点「去开启」弹系统标准对话框（回退链一级命中）；允许后 dumpsys 现 `com.hawkeyexb.ppass,10335`，**卡片消失**（ON_RESUME 刷新）|
| **DOG-02 反证** | ✅ PASS——`dumpsys deviceidle whitelist -pkg` 移除后重开 App，**卡片重现**（证明真读系统态非恒真）|
| UX-03 设置区 | ✅ 目视——仅充电/仅 WiFi/自动备份三开关在位；「插电+WiFi 时自动备份」规则行在 |
| UX-04 徽章 | ✅ 目视——顶部「随时可以备份」，无「直连」假话 |
| **待配对后补验**（三元组正反证 M/K、UX-01 暂停续传、UX-02 失败通知、UX-06 断开重建） | ⏳ 需先扫码重建配对——见「等用户」 |

### 15:00 加审（验收人，应执行 agent 请求）

| 交付 | 裁决 |
|---|---|
| #45 DOG-01d | ✅ 已合并（上轮，1ed5e65）|
| #46 BUMP-02 桌面版本 | ✅ **已合并**（907610f）：四件套对齐 0.2.1、漂移断言前置于任何改动、独立 workspace 的 lock 在目录内 cargo update -w（platform 0.1.0→0.2.1 属预期，version.workspace=true）。**合并卫生跟修一处**：diff 显示行的 ERE 转义被丢（裸 `+++` 非法，/usr/bin/grep exit 2 实测），已恢复 `\+\+\+` |
| **v0.2.1-test.3 出包** | ✅ **全绿（2026-08-06，Salamira，run 30980572190）**：四 job success（macOS arm64 签名门控 / Windows x64 未签名 / Android 签名 APK / Release 草稿）。**draft 9 资产**：`app-release.apk`（28.9MB，versionCode=2 同 test.2 可覆盖装，含 DOG-01d 修复）、`P-Pass-macos-arm64.dmg`（23.4MB，桌面 0.2.1）、`ppass-macos-arm64.zip`、`daemon.exe`、`testclient.exe`、`manifest.json`、`BUILD_INFO-windows-x64`、双平台 `SHA256SUMS-*`。三星真机启动验收挂验收人 |

### 13:47 巡检轮（验收人）

| 交付 | 裁决 |
|---|---|
| DOG-01d | ✅ **已合并**（1ed5e65）：_ID 投影 + cursor.count 合规写法；computeTripletSafe 生产函数 Throwable 兜底（测试共用，注入同型异常反证）。本地 android 74/74 |
| 下一手（执行 agent） | ①桌面版本号纳入 bump 并对齐 0.2.1（用户指令已发，若未做先做）；②打 **v0.2.1-test.3**（versionCode 不动），盯 run 全绿，资产清单写回本节 |
| 验收人待命 | test.3 全绿即 adb 装三星：首验启动不闪退，然后六项真机验收连跑 |

### 🔴 12:10 插播（验收人）：test.2 APK 三星启动必闪退——DOG-01d 卡

真机实锤（用户手机首启即崩，logcat FATAL 在案）：
`IllegalArgumentException: Invalid column count(*)` @ MediaScanner.countAll
(MediaScanner.kt:97) ← BackupUiStateHolder.refreshTriplet (启动即跑)。
JVM 单测摸不到真 MediaStore provider——三星（scoped storage 全家）不接受
projection 里的 SQL 函数。**test.2 的 APK 对有照片的真机=启动必炸，别装。**

```
## DOG-01d countAll 真机崩溃修复  级别 L1（加急，堵狗粮周）
blocker：countAll 用 projection ["count(*)"] 查 MediaStore——真机
  provider 拒绝（Invalid column），且 refreshTriplet 启动即跑、异常
  未接住 → 启动必闪退（三星实锤，logcat 在 NEXT.md 插播段）。
修法：①countAll 改合规写法——projection 只放 MediaColumns._ID，
  用 cursor.count 取数（scoped storage 不许 SQL 函数投影）；
  ②refreshTriplet/countAll 全链 try/catch——媒体查询失败退化为
  「三元组不显示」，绝不崩 App（真机教训与 T-052 同款：Throwable
  级兜底）；③反证测试：mock resolver 抛 IllegalArgumentException →
  refreshTriplet 不抛、triplet 为 null（贴输出）。
验收：gradle 全测绿 + CI 绿；真机启动验收挂验收人（我有设备）。
收尾：修完直接打 v0.2.1-test.3（versionCode 不用动，同 2 覆盖装；
  PPF_BUILD_VERSION 会带 test.3，DAE-01 接管口径 test.3>test.2 已支持）。
```

### 11:47 巡检轮（验收人）：DAE-02 合并 + 本机真实环境双验收

| 事项 | 结果 |
|---|---|
| DAE-02 | ✅ **已合并**（106cb57）：①plist KeepAlive → SuccessfulExit=false（纯函数化+单测）；②claim 提前到 transport bind 之前（identity.key 直接派生 node_id + bind 后漂移熔断 + QR 挪到 wait_online 之后）。本地 209/209（一次 blobs_resume 300s 超时，隔离复跑 6.4s 过=并发偶发）|
| 本机真实环境验收 | ✅ 新 daemon 上岗（/Applications，plist 新语义）后双测过：**信号杀 → 5 秒复活**（96670→96780）；**IPC step_down（exit 0）→ 15 秒不重拉**（launchctl PID=[-]）——churn 缺陷实锤已死。kickstart 恢复值班（96900，version 0.2.1）|
| 真机验收 | ⏳ 仍等 test.2 签名 APK——Downloads 里的 app-release*.apk 是昨天的 0.1.0 旧包（一个还是缺 .so 的残包），不是 0.2.1。见「等用户」§六.0 |

### 09:47 巡检轮（验收人）：BUMP-01 合并 + 本机 daemon 清理完成

| 事项 | 结果 |
|---|---|
| BUMP-01 返工 | ✅ **已合并**：`-uno` 修复在验收人机器复验 DIRTY=[]（未跟踪 .claude/ 不再误炸）|
| 本机 A 类孤儿 | ✅ **清完**：4 个 target/release/daemon（数据目录全在 /tmp 的 ppf-android-*/ppf-t054b，lsof 证据在案）已 kill，无复活 |
| 本机 B 类治理 | ✅ **完成**：launchd plist 原钉 src-tauri **dev 构建路径**（B 类病灶本尊）→ 一次性手工迁移（做 install_autostart 同款动作）：bootout → plist 改指 /Applications/P-Pass.app → bootstrap。**验证三连**：IPC status 报 version=0.2.1 / exe_path=/Applications/... / library_dir=用户真实库；devices.list 配对完整（鸿蒙 ALN-AL00 + 三星都在）；kill -TERM → **4 秒复活**（新 PID 70883）。/Applications/P-Pass.app 已被替换为「dev 壳 + 0.2.1 daemon」组合，用户装签名 test.2 dmg 覆盖即可（路径不变，launchd 跟着新二进制走）|

### DAE-02 卡（L2，清理实战挖出的两个设计缺陷）

```
## DAE-02 daemon 常驻纪律补遗  级别 L2
背景：验收人做本机 B 类清理时实锤两个缺陷（都有现场证据）。
缺陷①（KeepAlive 无条件重拉退位实例）：plist KeepAlive=<true/>——
  StandDown/step_down 都是 exit(0)，launchd 照样每 ~10s 重拉 → 每次
  重拉又退位 → 永久空转 churn。升级接管场景必现（旧 launchd 实例
  退位后被自己的旧 plist 无限重拉，直到新实例覆写 plist 才停）。
  修法：KeepAlive 改 <dict><key>SuccessfulExit</key><false/></dict>
  ——主动退位（exit 0）不重拉；崩溃/被杀（非零/信号）照样复活
  （pkill 3 秒复活验收不回归）。
缺陷②（QUIC bind 先于版本握手）：main.rs 里 transport bind 在
  claim_single_instance 之前——用户 config 钉固定端口（41145）时，
  新实例 bind 失败直接退出（"Failed to bind sockets"），版本握手
  根本走不到，接管永不发生（验收人实测：0.2.1 新实例 vs 0.1.0
  在位，bind 先炸）。修法：claim 提前到 transport bind 之前
  （socket_name 依赖 node_id——从 identity.key 直接派生，不必先
  bind endpoint），或 bind 失败时降级走一次 claim 再重试 bind。
可执行验收：①集成测试：固定端口 + 在位实例 → 新版本实例必须完成
  接管（不是 bind 失败退出）；②plist 断言 SuccessfulExit 键存在；
  ③pkill 复活回归不破（信号杀 → 3 秒复活）；④退位实例 exit(0) 后
  launchd 不重拉（sleep 15 后 launchctl list 该 label 无新 PID 或
  PID 不变，贴输出）。
反证：把 KeepAlive 改回 <true/> → 验收④必挂（贴输出后还原）。
证据：测试输出 + plist diff + 实测日志。
收尾：走 PR 等 review。
```

### 07:47 巡检轮（验收人）

| 交付 | 裁决 |
|---|---|
| H-10a(+fix) quickstart | ✅ **已合并**：资产名与 v0.2.1-test.2 实物逐字对上（dmg/apk）、排障链接存在、Windows 只有 CLI 与 draft 不可见两处限制写得诚实、en+zh 齐。README 里的 [截图: …] 占位符等真机验收时顺手补图 |
| BUMP-01 | ❌ **返工（一行）**：干净树断言用 `git status --porcelain` 把**未跟踪文件**也算脏——验收人机器上永远有 `?? .claude/`，实测 DIRTY=[.claude/]，bump 必误炸。改 `--porcelain -uno`（只看已跟踪改动，未跟踪本来就不会被显式 add 带进 commit）。`cargo update -w` 部分是对的，保留 |
| main CI | ✅ 转绿实锤（cb34e2b PR Checks success，dae_flow 版本推导修复生效）|

### 05:47 巡检轮补充（验收人）：TAG-01 连带事故与收尾

- **main 曾红两个 commit**（756332b/9fb339f 的 PR Checks 均 failure）：
  bump 0.1.0→0.2.1 打翻 dae_flow 两条测试——测试把版本**写死**成
  "0.2.0"/"0.1.0" 字面量，bump 后"newer"claimant 反而比在位旧 →
  TookOver 断言必挂。**产品逻辑没坏，是测试脆性**（每次 bump 必炸）。
  验收人本地复现（bump 复演 → 同两条红）后直修：版本改为从
  CARGO_PKG_VERSION 相对推导（same/newer/older 三助手），78/78 +
  全量 206/206 绿，`6029de3` 已推。这属于 DAE-01b 验收时验收人漏掉
  的脆性，责任在 review 侧，不记实施方。
- **Cargo.lock 缺口**：bump-version.sh 只改 Cargo.toml，首次构建后
  lock 的 workspace 成员版本项变脏——`6bb3239` 补上。**BUMP-01 微卡
  （L0）**：bump-version.sh 末尾追加 lock 同步（`cargo update -w -q`
  或等效）+ 断言 `git status` 干净，反证：删掉该步 → bump 后构建
  必出脏 lock（贴 git status）。
- **纪律重申（对实施方）**：直推 main 的 commit 与分支交付同规——
  **push 后必须等 PR Checks 结论**，红了立刻跟修或回滚，不许留红
  过夜。本次 756332b 红了之后又推了 9fb339f（还是红）才转去打 tag。
- **网络备注**：办公网到 GitHub 的 SSH/HTTPS 全断过一段，验收人临时
  走 `GIT_SSH_COMMAND="ssh -o ProxyJump=vultr-ppass"` 跳板完成收口；
  后续巡检若 fetch 超时直接用这招，别空转。

### TAG-01 出包卡（L1）

```
## TAG-01 打狗粮周 test tag  级别 L1
前置：已满足——main 已含 DOG-01/02/03、DAE-01、UPD-01、UX-01..07、
  UX-06b（Rust 206/206 + Android 73/73 绿）。
步骤（照 RELEASING.md）：①tools/bump-version.sh 0.2.1（DAE-01 的
  版本接管需要严格递增；versionCode 随之 +1）→ 单独 commit 进 main；
  ②打 tag v0.2.1-test.1 推送；③盯 release run 到全绿，逐条确认：
  APK 完整性断言 step success、macOS zip/dmg/app 齐、SHA256SUMS 两平台、
  manifest.json 在资产里；④run 链接和资产清单写回本卡验收记录。
反证：故意不 bump 直接打 tag → bump-version.sh 已拦（已 tag 版本拒绝），
  引用 REL-01 五态测试在案即可，不必实测。
收尾：NEXT.md 第五节勾掉「打 tag」，验收人接手真机批量验收。
---
✅ **验收记录（2026-08-06 凌晨，Salamira）**：
  - bump `756332b`：0.1.0→0.2.1（versionCode 1→2），diff 恰好只碰版本行
  - **v0.2.1-test.1 红（run 30949374415）**：Release 草稿 job「Sign update
    manifest」step 挂——`failed to decode base64 secret key: Invalid symbol
    10, offset 348`。根因 = CI `echo "$UPDATE_SIGNING_KEY" > key` 追加尾换行
    （key 文件 348B 单行 base64，offset 348 恰为 echo 补的 \n，tauri signer
    base64 解码不 trim）。修复 `9fb339f`：`printf '%s'` 逐字节还原 +
    重设 secret 无尾换行 + 本地 signer 签名预验证（cmp 字节一致）。
  - **v0.2.1-test.2 全绿（run 30950901275）**：四 job success——Android
    (signed APK, **Assert APK contains libiroh_ffi.so step success**)、
    macOS arm64（Pack self-contained zip + Bundle .app+dmg 均 success）、
    Windows x64、Release 草稿（**Sign update manifest step success**）。
  - Draft release `v0.2.1-test.2` 9 资产：app-release.apk、daemon.exe、
    testclient.exe、BUILD_INFO-windows-x64、ppass-macos-arm64.zip、
    P-Pass-macos-arm64.dmg、SHA256SUMS-macos-arm64、SHA256SUMS-windows-x64、
    manifest.json —— SHA256SUMS 两平台齐、manifest.json 在资产里 ✅
  - 链接：https://github.com/hawkeye-xb/P-Pass/actions/runs/30950901275
  - 下一手：验收人真机批量验收 + 本机 B 类孤儿清理 + 家人装包 → 狗粮周。
```

## 四、狗粮周阻塞卡（产品档案 §三之五 f 裁决：不落则狗粮周作废）

> **当前队列顺序（2026-08-06 凌晨出包轮更新）**：✅ TAG-01 已完成
> （v0.2.1-test.2 全绿出包，验收记录见第三节卡体下）。
> **本节下方的 DOG-01/02、DAE-01、DOG-03 原卡与 UX-01..06 全部已
> 合并收口，仅作历史参照——不要重复做。** 真机验收项由验收人在
> TAG-01 出包后批量执行。

> 产品输入：docs/product/2026-08-04-experience-gaps.md + dogfood-week-cases.md。
> 全部按 task-card-template.md，可直接转发云端 agent。

```
## DOG-01 备份恒真三元组 + per-device 水位  级别 L2
目标：手机端「手机 N 张 · 已备份 M · 待备份 K + 最后成功时间」持久态
  （重开 App 不归零）；daemon IPC 暴露 per-device 备份水位（狗粮周
  agent 日报 + 桌面活动记录 + 两端可见的同一数据源，一鱼三吃）。
范围：apps/android（Backup tab UI + 状态缓存表 + exist-check 客户端）、
  crates/daemon（IPC status 或新方法 device.watermarks，数据源=现有
  backup_watermark/audit 表）、crates/proto（如需新消息，金样本随行）。
架构预留（产品档案 §三之四，必须遵守）：状态缓存 key=(hash, remote_id)，
  落 per-remote 目录；exist-check 复用 manifest「给 hashes 回 missing」
  语义（只查不传，不新增协议动词）；分母=当前扫描范围（范围选择是
  另一张卡，口径留缝：常量一处定义）。
可执行验收：①三星实测——备份若干张，杀 App 重开，三元组不归零且
  M/K 正确；②断网重开 App，三元组显示缓存值+不可达提示，不归零不崩；
  ③`ipc device.watermarks`（或扩展 status）返回每设备 {name, last_backup_at,
  asset_count}，与 sqlite 直查一致（贴对照输出）；④gradle 全测绿。
反证：把 exist-check 响应 mock 成全 missing → 三元组 K 必须=N（贴输出）。
证据：真机截图 + IPC 输出 + 测试输出。
收尾：走 PR 等 review；ROADMAP/PROGRESS 一行。
```

```
## DOG-02 ROM 电池优化白名单引导  级别 L1
目标：鸿蒙/三星杀后台是 A2 case 的已知咬点——App 检测「未加白」状态，
  备份页出引导卡片，一键跳系统设置（REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
  / 厂商设置页 intent 回退链），加白后卡片消失。
范围：apps/android（检测 PowerManager.isIgnoringBatteryOptimizations +
  引导 UI + 厂商 intent 表：鸿蒙/三星/通用回退）。
可执行验收：①三星真机：`adb shell dumpsys deviceidle whitelist` 前后
  对照，引导流程走完 App 出现在白名单（贴输出）；②已加白时卡片不出现；
  ③拒绝授权不崩溃、卡片保留。
反证：`adb shell cmd deviceidle whitelist -com.hawkeyexb.ppass` 移除后
  重开 App → 卡片必须重现（贴截图）。
收尾：走 PR 等 review。
```

```
## DAE-01 daemon 常驻纪律最小集（治 B 类孤儿）  级别 L2
目标：狗粮周每次装包换版都会复制「旧 daemon 值班、新 daemon 上不了岗」
  （用户机实锤：launchd 至今指向 7/31 开发构建路径）。最小集三件：
  ①单实例锁：IPC socket 由「unlink 后 bind」改为「先试连接——活实例
  在即版本握手，死 socket 才清理重绑」（现状 unlink-before-bind 恰好是
  后来者盲杀前任的反模式）；②稳定路径：install_autostart 的 plist
  永远指向稳定安装路径（app bundle 内 sidecar），绝不指 target/ 开发
  路径；③升级退位：版本握手 newest wins——新实例发现老版本值班 →
  IPC 通知退位 → 老实例优雅退出，launchd 用新 plist 重拉。
范围：crates/daemon（ipc.rs 锁与握手、main）、crates/platform
  （install_autostart 路径）、apps/desktop（向导/托盘启动路径核对）。
不准动：IPC 现有七方法语义；identity.key 位置。
可执行验收：①同 data_dir 起第二个 daemon → 旧版本号者退出、新者接管，
  IPC status 报 PID/版本/路径/启动时间（贴两实例日志）；②pkill 后
  launchd 3 秒复活（回归既有行为）；③集成测试钉住「双实例收敛到一」。
反证：把版本比较逻辑反转 → 测试必红（贴输出后还原）。
证据：测试输出 + 两实例日志。
收尾：走 PR 等 review。本机清理（3 个 A 类孤儿 + B 类旧 daemon 换正式
  接管）由主会话在合并后执行并贴证。
```

```
## DOG-03 夜间剧本脚本化  级别 L1
目标：dogfood-week-cases.md 的 agent 全自动 case 脚本化，三晚编排可一键跑。
范围：tools/dogfood/ 新目录——night1.sh/night2.sh/night3.sh（按 case 文件
  的三晚编排）+ 晨间对账 morning-report.sh（D1/D2：sqlite 对账 originals/
  水位/audit，输出 markdown 日报）；半自动 case（A1/A3/A7/B7 等）各出
  一页操作单 docs/runbook/dogfood-manual-cases.md。
依赖：DOG-01 的 per-device 水位 IPC（日报数据源）——可先用 sqlite 直查
  占位，DOG-01 合并后切换。
可执行验收：night1.sh 在三星+本机组合上完整跑一遍自动部分（A4 熄屏夜
  可用 30 分钟压缩档演练），morning-report.sh 产出日报（贴全文）；
  所有脚本 bash -n + 带 cleanup trap + PPF_BIND_ADDR 隔离（沿用既有教训）。
反证：故意让一台设备水位不推进 → 日报必须亮红该设备（贴输出）。
收尾：走 PR 等 review。
```

### 尽量项轻量卡（阻塞队列+返工清空后按序做；共用规则：走 PR、
### 证据照模板、产品语义以 docs/product/2026-08-04-experience-gaps.md 为准）

- **UX-01 备份中可暂停**（L1，移动端）：备份进行中按钮变「暂停」，暂停
  即中断当前批（幂等管线保安全），再点续传。验收：三星实测暂停→续传
  收敛缺 0；反证：暂停后 sqlite 无半条 asset 记录。
- **UX-02 失败通知，成功沉默**（L1，移动端）：批次有失败才发系统通知
  （「N 张照片没备份成功，打开看看」），点开落在失败清单；成功零通知。
  验收：mock 一张失败→通知出现；全成功→零通知（贴 dumpsys notification）。
- **UX-03 后台规则一行+极简设置**（L1，移动端）：备份页一句「插电+WiFi
  时自动备份，无需打开 App」+ 设置两开关（仅充电/仅 WiFi，写 WorkManager
  约束）。验收：改开关后 dumpsys jobscheduler 约束随之变化（贴对照）。
- **UX-04 「已直连」徽章降级**（L0，桌面）：顶部徽章只说服务态
  （运行中/已停止）——现状 OnlineDirect 是状态机默认值，是假话
  （产品档案 §二事实核查）。连接状态归属未来设备行，本卡只做降级。
  验收：徽章文案不再出现「直连」字样。
- **UX-05 folder.set 诚实化**（L0，桌面）：改库位置的确认文案如实说
  「重启后生效；已有照片不会迁移」。验收：文案截图。
- **UX-06 移动端「暂停自动备份」+「断开连接」**（L1）：设置里全局暂停
  开关（取消周期任务）+ 断开配对（清 pairing/watermark/状态缓存，
  警示页照产品档案 §二移动端 1 的告知清单）。验收：断开后 daemon 端
  hello 仍被 authz 拒；重扫码可重建。
- **UX-07 daemon ephemeral 模式**（L1）：`--ephemeral` 或 stdin EOF 即退，
  测试脚本用它杜绝 A 类孤儿。验收：起进程关 stdin → 3 秒内退出；
  dogfood 脚本切换到该模式。

## 五、发布链路（更新）

**狗粮周阻塞全清**（DOG-01/02/03、DAE-01、UPD-01、UX-01..06 全部
已合，main 全量 android 71/71 + nextest 206/206 绿）→ UX-06b/UX-07
小卡收尾 → **✅ TAG-01 出包已完成**（bump 0.2.1 `756332b` + 修复
`9fb339f` + **v0.2.1-test.2 全绿 run 30950901275**，draft 9 资产齐，
验收记录见第三节卡体）→
验收人批量真机验收（DOG-01 三元组正反证、DOG-02 dumpsys 白名单、
UX-01 暂停续传、UX-02 通知、UX-03 约束对照、UX-06 断开后 hello 拒）+
本机 B 类孤儿清理贴证 + 家人装包 → **压缩版狗粮周开跑**（night1..3
已在 tools/dogfood/）→ 滚动衔接 M3 私测。H-02（用户）并行不阻塞。

## 六、等用户

0'. **【最优先·30 秒】扫码重建配对**——真机验收后半段（三元组 M/K 正反证、暂停续传、失败通知、断开重建）都要先有配对。桌面 App 出二维码 → 三星 P-Pass「备份」页扫 → 电脑点允许。扫完告诉我，我一口气补完剩余四项。
0. **【新增·最优先】给验收人 v0.2.1-test.2 的签名 APK**——draft release
   下载需登录态，验收人拿不到。你下载 app-release.apk 丢到
   ~/Downloads/ 或直接说"发布了"（publish 后匿名可下）。拿到后我批量
   跑六项真机验收（三星在线，升级安装不动配对）。
1. **H-02 Apple 签名**：操作单在 docs/runbook/h02-apple-signing.md，
   约 10-15 分钟，需要你的 Apple ID 和钥匙串授权。
2. **UPD-01 桌面签名密钥对**：tauri updater 的 minisign 私钥必须你本人
   生成（命令在 feat/upd-01-auto-update 的 PR 描述里），agent 不代生成。
3. **桌面端删两个旧三星设备**（913D2DC2、D3AA8DF3）——上次真机
   验收换包留下的重复配对。
