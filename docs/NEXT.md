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

## 三、这一轮交付的 review 状态（2026-08-05 21:47 巡检轮，第三批四交付已审）

| 交付 | 裁决 |
|---|---|
| DAE-01b 返工 | ✅ **已合并**（dbcad43）：前任 token 握手正确（活 socket+错 token → StandDown 绝不抢绑，反证测试 wrong_token_never_grabs_a_live_socket 在案）；build.rs 烤入 PPF_BUILD_VERSION（release.yml macOS/Windows 双 job 注入）；version_cmp 预发布数字段 test.8>test.7。本地 nextest -p daemon 72/72 |
| DOG-03 | ✅ **已合并**（代码侧 PASS：bash -n ×4、night 脚本 trap+PPF_BIND_ADDR、morning-report 只读对账+--expect-stall 反证豁免）。night1 实跑验收留到狗粮周开跑当晚，验收人执行 |
| DOG-01b 返工 | ❌ **再返工**（见下 DOG-01c 卡）：ConfirmedStore 架构对了，但 recordRun 接线把「上传前的 missing」当「跑完还缺的」——首次备份 100 张成功后 M=0 且永远为 0。单测又是绕过生产语义喂手工集合 |
| UPD-01 返工 | ❌ **第三轮返工**（见下 UPD-01c 卡）：i18n blocker 只修一半——Android 副本同步了，但 keys.rs 没注册 ui.update_* 三键，diag 测试 panic（"unregistered key"）。**纪律问题：带红 CI 交付**（exit 100 在分支上可见，交付前必须自查 CI）。suspend+IO 下载、App.svelte 404 静默两处修复本身是对的，保留 |
| H-10a-fix | ❌ 未交付，卡仍挂 |
| 前轮存档 | REL-01/DOG-02（真机验收挂签名包）/OPS-01/E2E-01/DAE-01 已合，见 git 历史 |

### DOG-01c 返工卡（阻塞 DOG-01 验收，级别 L2，在 feat/dog-01-watermarks 原分支继续）

```
## DOG-01c recordRun 接线修复  级别 L2
背景：DOG-01b 的 ConfirmedStore 架构正确（(hash,remote) per-remote 目录、
  N=MediaStore 全量 count、tmp+rename、损坏不崩）——全部保留。
  坏的是接线语义。
blocker（missing 时序错位）：BackupRunner.report.missing 是**上传前**
  manifest 应答的缺失集合；随后这些文件全被上传且 commit 成功。但
  BackupUiStateHolder 传 confirmed = allHashes − missing（只剩 duplicates）、
  missing 原样减掉——刚上传成功的照片被立刻从缓存删除。
  失败场景：首次备份 100 张**成功** → 缓存 = (∅+∅)−100 = ∅ → UI 显示
  「手机 100 张 · 已备份 0」，且增量扫描永不重新 offer 旧照片 → M 永远 0。
  DOG-01b 的单测绿是因为在 ConfirmedStore 层手工喂集合，没走
  BackupRunner 生产语义——与 DAE-01 第一版同款病，这是第二次，
  以后测试必须从生产调用路径（至少 BackupRunner 报告→recordRun）连起来测。
修法：
  ①一次 commit 成功后，本次 candidates 全部确认：confirmed = allHashes，
    减项 = ∅（duplicates 和刚 ingested 的都在家）；
  ②漂移校准（电脑端库被删/换库）不能挂在备份运行上（增量 manifest
    根本不含旧 hash）——单独做只查不传的 exist-check：用缓存里的
    hash 集发 begin+manifest 读 missing 后不 push 不 commit（或加
    显式 abort），missing 的从缓存移除。触发时机：App 打开或备份前，
    daemon 可达才跑，不可达跳过（三元组显示缓存值）。
  ③WorkManager 路径（BackupWorker）同步同一修法。
  ④顺手：把误入分支的 tmp-pr-t042b.md 删掉。
不准动：ConfirmedStore 本体、MediaScanner.countAll、DOG-01 daemon 侧。
可执行验收：①集成级单测走真实调用链（构造 BackupReport{missing=上传前
  集合} → recordRun）：首次 100 张全 missing 全上传成功 → M 必须=100
  （这条就是本 bug 回归测试）；②两次运行 100→5 ⇒ N=105 M=105；
  ③漂移：缓存 100 条、exist-check 回 30 条 missing → M=70；
  ④三星实测（杀 App 重开不归零、新拍两张 K=2）——设备不在则标"挂验收人"。
反证：把①的 confirmed 改回 allHashes−missing → 测试必红（贴输出后还原）。
证据：单测输出 + 关键 diff。
收尾：走 PR 等 review。
```

### UPD-01c 返工卡（级别 L1，在 feat/upd-01-auto-update 原分支继续）

```
## UPD-01c i18n 注册收尾  级别 L1
背景：UPD-01 第二轮返工把 Android 副本字典同步了、suspend+IO 下载和
  App.svelte 404 静默都对——但 keys.rs 没注册新键，crates/diag 测试
  all_keys_translated_in_en_and_zh panic："i18n/en.json contains
  unregistered key: ui.update_available (register it in keys.rs)"。
  **交付时分支 CI 就是红的（exit 100），没自查——以后红 CI 不许交付，
  除非 PR 描述里写明"红因 X，与本卡无关，证据 Y"。**
修法：keys.rs 注册 UI_UPDATE_AVAILABLE / UI_UPDATE_INSTALLED /
  UI_UPDATE_FAILED 三键（进 ALL，len 断言随之 61→64 或按现状），
  确认根字典/Android 副本四个 json 与 ALL 完全一致。
可执行验收：cargo nextest -p diag 全绿 + Android DiagTest 相关单测绿 +
  分支 CI 四 job 全绿（贴链接或 API 输出）。
反证：从 en.json 临时删掉 ui.update_failed → diag 测试必红（贴输出后还原）。
收尾：走 PR 等 review。合并后 UPD-01 整卡进入待验收（桌面篡改反证已在案）。
```

## 四、狗粮周阻塞卡（产品档案 §三之五 f 裁决：不落则狗粮周作废）

> **当前队列顺序（2026-08-05 21:47 巡检轮更新）**：DOG-01c →
> UPD-01c → UX-01..07。返工都在原分支继续（不开新分支）。
> DAE-01(+b)/DOG-03/DOG-02/REL-01 已合并，不要重复做。
> **DOG-01 原卡（下方全文）已由 DOG-01b 部分实现，只剩 DOG-01c
> 的接线修复——别按原卡重做。**

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

**只剩 DOG-01c 阻塞**（DOG-02/DAE-01/DOG-03 已合）→ 合并后打新
test tag 出包（记得先 bump-version.sh，DAE-01 版本注入也吃 tag）→
家人手机装 APK + 媳妇 Mac 换 dmg + 本机 B 类孤儿清理（验收人执行并
贴证）+ DOG-02/DOG-01 三星真机验收（验收人）→ **压缩版狗粮周开跑**
（night1..3 脚本已在 tools/dogfood/）→ 滚动衔接 M3 私测。
H-02（用户）、UPD-01c（审后合）并行不阻塞。

## 六、等用户

1. **H-02 Apple 签名**：操作单在 docs/runbook/h02-apple-signing.md，
   约 10-15 分钟，需要你的 Apple ID 和钥匙串授权。
2. **UPD-01 桌面签名密钥对**：tauri updater 的 minisign 私钥必须你本人
   生成（命令在 feat/upd-01-auto-update 的 PR 描述里），agent 不代生成。
3. **桌面端删两个旧三星设备**（913D2DC2、D3AA8DF3）——上次真机
   验收换包留下的重复配对。
