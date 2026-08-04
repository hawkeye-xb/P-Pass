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

## 三、这一轮交付的 review 状态（2026-08-05 晚，第二批四交付已审）

| 交付 | 裁决 |
|---|---|
| REL-01 返工 | ✅ **已合并**（b3e5e87：三处 sed 全改 `-i.bak && rm`，bash -n 过）|
| DOG-02 | ✅ **已合并**（代码侧 PASS：四级回退链 resolveActivity 过滤、ON_RESUME 刷新、全不可用静默；**真机验收挂起**——手机上是在用的 release 签名包，装 debug 必须卸载，验收人裁决不动用户环境，挂到下个签名 test tag 我跑 dumpsys 正反证）。分支 CI 红已查实为偶发：Rust 树与绿基点 0aae850 逐字节相同 + 本地复跑 193/193 绿 |
| DAE-01 | ❌ **返工**（见下 DAE-01b 卡，blocker 级）|
| DOG-01 | ❌ **返工**（见下 DOG-01b 卡，blocker 级）|
| UPD-01 | ⚠️ 返工中（前轮裁决不变）：①i18n 捆绑字典漂移（Android 副本没同步，DiagTestT 红）；②Android downloadAndInstall 主线程网络异常被吞。另修：App.svelte 404 静默、npx pin、manifest darwin 挂账注明、ROADMAP 文案、desktop 篡改反证 |
| H-10a-fix | ❌ 未交付，卡仍挂 |
| OPS-01 / E2E-01 | ✅ 前轮已合（存档见 git 历史）|

### DAE-01b 返工卡（阻塞 DAE-01 验收，级别 L2）

```
## DAE-01b daemon 单实例握手修复  级别 L2
背景：DAE-01 主体架构正确（probe→版本握手→newest wins，Equal 退位
  防 launchd 重拉死循环），但有一个生产必现 blocker + 一个版本口径缺口。
blocker①（token 错位）：main.rs 用本实例新生成的 rand_token() 去探测
  前任，而前任只认它自己启动时写进 data_dir/ipc.token 的 token——
  生产上 probe 必然认证失败断连 → peer_call 返回 None → 误判死 socket
  → remove_file 抢绑。后果：旧 daemon 没死、挂在已 unlink 的 socket 上
  变幽灵（占库锁和 iroh endpoint），比 unlink-before-bind 更糟。
  测试没抓到是因为 dae_flow.rs 两实例共享写死的 [7u8;32]。
  修法：claim_single_instance 探测前先读现存 data_dir/ipc.token
  （前任的 token）用它握手；claim 成功后才生成/写入自己的 token。
blocker②（版本口径）：CARGO_PKG_VERSION 不含 test 后缀——test.7 和
  test.8 的 daemon 都自报 0.2.0 → Equal → 新包退位，狗粮周换 test 包
  接管永不触发。修法（二选一，PR 里说明取舍）：
  a) release.yml 构建时把完整 tag 注入（如 build.rs 读 PPF_BUILD_VERSION
     env 落 option_env!，version_cmp 已支持 -test.N 数字段则需扩展：
     同核心时比较预发布数字段，test.8 > test.7）；
  b) 流程规定每个 test tag 前必跑 bump-version.sh（REL-01 工具），
     Cargo 版本严格递增。
不准动：Equal → StandDown 语义（防同版本互踢循环）；IPC 七方法契约。
可执行验收：①集成测试改为两实例各自独立 token + 前任 token 落
  ipc.token 文件（复现生产时序），newer 接管/equal 退位仍过；
  ②反证：故意让新实例用随机 token 探测 → 必须得到 StandDown 或
  显式"auth failed"处理路径，绝不 Proceed 抢绑（贴测试输出）；
  ③blocker② 选 a 则加 version_cmp("0.2.0-test.8","0.2.0-test.7")
  == Greater 的测试；选 b 则在 RELEASING.md 写明并给 bump 演示输出。
证据：测试输出 + 关键代码段。
收尾：走 PR 等 review。
```

### DOG-01b 返工卡（阻塞 DOG-01 验收，级别 L2）

```
## DOG-01b 三元组口径修复  级别 L2
背景：DOG-01 的 daemon 侧（list_device_watermarks SQL 视图 + IPC
  device.watermarks + 两条测试）已过可保留；手机端三元组口径错误。
blocker（增量当全量）：tripletOf 拿 scanSince(watermark) 增量运行的
  offered/ingested 当 N/M——手机 100 张备完后新拍 5 张，第二次备份后
  UI 显示「手机 5 张 · 已备份 5」。恒真三元组变假话。
修法（按原卡架构预留实现，不许再绕）：
  ①状态缓存表 key=(hash, remote_id)，落 per-remote 目录——记录哪些
    本地资产已被哪个 remote 确认（备份成功即写入；不依赖单次运行报告）；
  ②N = 当前扫描范围全量 count（MediaStore COUNT 查询，便宜，不需要
    重 hash）；M = 缓存表中该 remote 已确认条数；K = N − M clamp ≥ 0；
  ③exist-check 校准：备份运行时复用 manifest「给 hashes 回 missing」
    语义（只查不传）——daemon 回 duplicates/missing 时同步修正缓存表
    （处理"电脑端库被删/换库"的漂移）。增量扫描省 hash 的优化保留。
可执行验收：①单测：模拟两次运行（全量 100 → 增量 5）→ 三元组必须是
  N=105 M=105，不是 N=5（这条就是本次 bug 的回归测试）；②三星实测：
  备份→杀 App 重开不归零、新拍两张重开 K=2；③断网重开显示缓存值；
  ④`ipc device.watermarks` 与 sqlite 直查一致（daemon 侧保留项复验）。
反证：清空状态缓存表 mock exist-check 全 missing → K 必须 = N（贴输出）。
证据：单测输出 + 真机截图（真机部分若设备不在，明确标"挂验收人"）。
收尾：走 PR 等 review。
```

## 四、狗粮周阻塞卡（产品档案 §三之五 f 裁决：不落则狗粮周作废）

> **当前队列顺序（2026-08-05 晚更新）**：DAE-01b → DOG-01b →
> DOG-03 → UPD-01 返工 → UX-01..07。DOG-01/DAE-01 原卡代码留在
> 各自分支上，返工在原分支继续（不开新分支）。DOG-02/REL-01 已合，
> 不要重复做。

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

DOG-01/02 + DAE-01 合并 → 打新 test tag 出包 → 家人手机装 APK +
媳妇 Mac 换 dmg + 本机 B 类孤儿清理 → **压缩版狗粮周开跑**（三晚编排，
gate 语义修改建议见 dogfood-week-cases.md）→ 滚动衔接 M3 私测。
H-02（用户）、UPD-01（审后合）、REL-01（返工后合）并行不阻塞。
