# 升级兼容承诺（REL-06）

> **草案，待拍板**：标 `D1`–`D6` 的条款还没有定，承诺不生效；定稿前 [#432](https://github.com/hawkeye-xb/P-Pass/issues/432) 的验证矩阵不开验。

本文回答「老版本 → 新版本」时 P-Pass 保证什么。它是 #432 验证矩阵的判据：每一格验的是下面某一条承诺。
「依据」一列：E2 / E3 沿用 AGENTS.md 的证据分级（E2 contract 测试、E3 真机真环境）；「读码」表示只有代码阅读，没有测试或实跑。

## 0. 口径

| 术语 | 含义 |
|---|---|
| 版本 | **已打 tag 并发布的 release**（`v<X.Y.Z>[-test.N]`，`docs/RELEASING.md` §1）。两个 tag 之间的本地构建版本串可能相同（#432 评论：main 与 test.2 同为 `0.6.0-test.2`），不在承诺范围内 |
| 可独立更新的单元 | 只有两个：**桌面（含 daemon）**、**Android**。daemon 作为 sidecar 随桌面包分发，不存在单独升级 daemon 的场景 |
| 发布侧单元 | 更新通道 / manifest（`docs/RELEASING.md` §3.5、§3.6） |
| 相邻版本 | 同一通道里按发布顺序紧挨着的两个 tag |

当前基线（2026-09-29）：最新发布 `v0.6.0-test.2`；main 为 `0.6.1-test.1` / versionCode 37；**正式版从未发布**（`v0.3.1` 是 Draft），stable 通道没有 manifest，客户端静默「无更新」。

## 1. 现有兼容机制盘点

| 机制 | 在哪 | 实际作用 | 依据 |
|---|---|---|---|
| `PROTO_VER` / `MIN_SUPPORTED_VER` | `crates/proto/src/version.rs`、`apps/android/.../proto/Proto.kt:26-27` | 两者自始至今都是 1。`Req.min_ver` 只有声明和默认值，**daemon 与 Android 都没有代码读它做判断**；hello 里的 `proto_ver` 也没有被检查 | 读码 |
| ALPN 版本 | `crates/transport/src/lib.rs:28-35`（`ppf/ctrl/1`、`ppf/blobs/1`…） | 破坏性变更开新 ALPN、过渡期双栈。至今没有用过 | 读码 |
| 加字段惯例 | `crates/proto/src/msgs.rs` 顶部：每个 struct `#[serde(default)]`，可选字段 `skip_serializing_if`，无 `deny_unknown_fields` | 旧帧缺字段取默认值；新帧多出的字段被旧端忽略 | E2 |
| Android 解码宽容 | `Proto.kt` `ProtoJson`：`ignoreUnknownKeys = true` | 旧手机收到新 daemon 的新字段不崩 | E2 |
| 旧帧用例 | `msgs.rs`：`hello_without_health_omits_the_key_and_old_frames_still_parse`、`flow_fetch_request_size_bytes_defaults_to_unknown_for_old_phones`、`asset_meta_source_roundtrip_and_old_frame_defaults_to_none`、`flow_audit_event_old_frame_without_round_id_parses_as_none`；`crates/proto/tests/snapshots.rs`：`thumb_data_from_an_old_daemon_decodes_as_a_real_thumb` | 锁住「旧帧仍能解」 | E2 |
| 金样本 | `crates/proto/tests/snapshots/*.snap`（35 个）+ Android `GoldenDriftTest` | 两端 wire 形状同一 commit 内对齐；既有 `.snap` 零改动 = 没有破坏旧形状 | E2 |
| hello 能力位 | `crates/daemon/src/router.rs` `SERVER_CAPABILITIES`：`thumbnail.v1`、`pair.status.v1`、`pair.cancel.v1` | 新行为按能力协商开启，**这是目前唯一真正在起作用的版本协商** | E2 |
| 桌面索引迁移 | `crates/storage/migrations/0001…0010`，`crates/storage/src/db.rs` 嵌入 `sqlx::migrate!`，首次打开自动跑，记在 `_sqlx_migrations` | 只进不退；旧程序打开已迁移的库报 `migration N was previously applied but is missing in the resolved migrations` 并拒绝启动 | E3（#432：7 → 10） |
| 库比程序新的提示 | `apps/desktop/src/lib/daemonStartupError.js`：匹配上面那句，显示「这个版本比你的照片库旧。请装回新版本。」 | DESK-09 [#103](https://github.com/hawkeye-xb/P-Pass/issues/103)，代码与单测已合入，**真机验收欠账，卡仍 OPEN** | E2 |
| 桌面数据目录搬迁 | `crates/platform/src/data_migration.rs`（DESK-24 [#173](https://github.com/hawkeye-xb/P-Pass/issues/173)） | 失败时退化为「保持原样」，不切到空目录 | E3（#432 Windows） |
| Android 账本 | `apps/android/.../backup/order/SqliteOrderStore.kt`，`SCHEMA_VERSION = 3` | `onUpgrade` 与 `onDowngrade` 都是**删表重建**，不做数据迁移（注释依据：#413 契约 §0「测试设备上都是测试数据」） | 读码；升级路径从未实跑（#432 A 格 `user_version` 3 → 3） |
| Android 一次性迁移 | `AndroidFlowRuntime.kt` `migrateLegacyFlowState`，marker `files/flow-migrated-arch13` | #413 起删除旧账本 `flow-state/` 与旧保护状态文件，只做一次 | 读码 |
| Android 私有状态清单 | `backup/DisconnectStateManifest.kt`（MOB-95 [#282](https://github.com/hawkeye-xb/P-Pass/issues/282) / [#528](https://github.com/hawkeye-xb/P-Pass/pull/528)） | 列全手机每一样持久状态及断开时的处置；升级数据承诺按它逐项对账 | E2 |
| 版本号规则 | `tools/bump-version.sh`、`docs/RELEASING.md` §1/§5 | 新版本必须高于当前；tag 不复用；Android versionCode 单调 +1 | E2 |
| 更新判定 | Android `update/UpdateChecker.kt:67` `isNewer`、daemon `crates/daemon/src/update.rs:141` `is_newer` | 候选版本**严格更新**才提示；正式版 > 同核心预发布 | E2 |

盘点出的缺口（只登记，另开卡处理）：

- 桌面索引没有「旧版本真实库 → 新程序」的自动测试（没有测试引用 `_sqlx_migrations` 或旧库 fixture），只靠 #432 B 格真机。
- Android 账本 schema 升级路径（`onUpgrade`）没有测试，也没有真机记录。
- `min_ver` 是空机制：写在协议里，但不生效。

## 2. 升级路径

| 路径 | 方式 | 承诺（草案） | 验证格 |
|---|---|---|---|
| 桌面 旧 → 新 | 手动下载安装包覆盖安装（桌面应用内更新受 REL-05 [#232](https://github.com/hawkeye-xb/P-Pass/issues/232) / [#398](https://github.com/hawkeye-xb/P-Pass/issues/398) 所限，manifest 没有桌面条目） | 覆盖安装后 daemon 正常起，数据按 §3 保留 | B |
| Android 旧 → 新 | 应用内更新（manifest `android-arm64` 条目）或覆盖安装 APK | 同签名覆盖安装，数据按 §3 保留；传输中途升级，未完成的单由新版续完 | A |
| 版本跨度 | — | **D1** 待拍板 | A、B |
| 起算版本 | — | 建议从 `v0.6.0-test.2` 起算：更早的版本升到 #413 之后，`flow-state/` 旧账本会被一次性删除（见 §1），不属于平滑升级 | A、B |
| 两端错配 | 手机与桌面各自升级 | 见 §4；互通范围 **D3** 待拍板 | C |
| test ↔ stable 通道 | 设置页切换 | 当前 test 版比 stable 新时切到 stable 不会提示「更新」（`isNewer` 严格大于），会停在 test 版直到 stable 追上；边界 **D6** 待拍板 | D |

## 3. 数据承诺

「保留」指升级后内容不变、功能照常可用；存放位置以 `DisconnectStateManifest.kt` 与桌面数据目录为准。

| 数据 | 存放 | 升级时发生什么 | 承诺（草案） | 验证格 / 现有证据 |
|---|---|---|---|---|
| 原图 | 桌面 `originals/` | 不改动文件 | 不丢、逐字节不变 | B：Windows 11 张 SHA256 逐一相同（#432 Windows 第二轮） |
| 照片索引 | 桌面 `.ppf/index.sqlite` | sqlx 迁移自动前进 | 迁移成功；各表行数不减 | B：`_sqlx_migrations` 7 → 10、11 张表行数不变 |
| 配对设备 | 桌面 `device` 表、配对纪元 | 同库 | 已配对仍可用，已吊销仍被拒 | B：配对行完全相等、已配对身份可 browse、未配对身份 `err.not_paired` |
| 审计记录 | 桌面 `audit_*` 表 | 同库 | 不丢 | B：行数不变 |
| daemon 身份 | 桌面 `identity.key` | 不改内容 | NodeId 不变 | B：NodeId 相同；SEC-10 [#445](https://github.com/hawkeye-xb/P-Pass/issues/445) 会收紧文件权限，属预期变化 |
| 桌面配置 / 数据目录 | `config.toml`、平台数据目录 | DESK-24 搬迁 | 搬迁失败等于没搬 | B：Windows 实测搬迁 |
| 手机配对 | `files/pairing.json` | 不改动 | 逐字节不变 | A：两轮均相同 |
| 手机身份 | `files/identity.key` | 不改动 | 不变 | A：待补（配对沿用可间接证明，未直接比对） |
| 相册范围 | `shared_prefs/backup_scope-<id>.xml` | 不改动 | 保留 | A：Camera 范围保留 |
| 备份设置 / 自动备份开关 | `files/backup-settings.json`、`files/auto_backup_prefs.json` | 带旧字段兼容读取（`BackupSettingsTest`、`AutoBackupPrefsTest` 的 legacy 用例） | 保留 | A：待补逐项比对 |
| 备份账本（order 状态、跳过名单、审计 outbox） | `databases/backup-orders.db` | schema 版本不变时原样保留；**schema 升级时删表重建** | **D5** 待拍板。现状下能保证的只有：照片不重复入库（桌面按内容哈希去重），不能保证 `skip_list`（「取消剩余」的意图）与未送达的 `audit_outbox` 保留 | A：只验过 schema 不变的情况（3 → 3，行数 26/0/26/1/3 不变） |
| 续传 | 账本 + 桌面 | 升级后重开 App 续跑 | 不重不漏 | A：+4 张正好 +4 offer；中途升级 113/116 单全部 CONFIRMED、无重复 |

## 4. 协议承诺

### 4.1 演进规则（现行做法，成文即约束）

1. 加字段：`#[serde(default)]` + 可选字段 `skip_serializing_if`；既有 `.snap` 必须零改动，新形状加新 `.snap`，并补一条「旧帧仍能解」用例（先例：#527 `ThumbData`、SYNC-05 `asset_meta_source…`）。
2. 新行为：daemon 在 hello `SERVER_CAPABILITIES` 宣告能力位 `<name>.v1`，手机见到能力位才走新路径（先例：#468 `pair.status.v1`、#503 `pair.cancel.v1`）。旧路径在承诺的错配范围内保留（#468 保留了旧手机的同步 `pair.request`）。
3. 破坏性变更：开新 ALPN（`ppf/ctrl/2`）并双栈过渡，附 ADR。`PROTO_VER` 与 ALPN 同步递增。

### 4.2 错配时的行为

| 组合 | 原则（按现有 PR 的做法） | 先例 |
|---|---|---|
| 旧手机 + 新桌面 | 新桌面**照旧服务**旧形状，旧手机无感；可见差异须在 PR 里逐条列出 | [#468](https://github.com/hawkeye-xb/P-Pass/pull/468)：旧手机不带 flag 走同步形状，语义不变；[#503](https://github.com/hawkeye-xb/P-Pass/pull/503)：新能力只是多宣告一项；[#527](https://github.com/hawkeye-xb/P-Pass/pull/527)：新字段只出现在占位图响应里，旧手机忽略 |
| 新手机 + 旧桌面，缺的是**必需**能力 | **一次性明确报错**：先查 hello 能力位，缺就提示「桌面版本过旧」（`err.unsupported`），不提交请求、不消耗 token、不重试、不做长等待降级 | #468 `pair.status.v1`；NET-24（`NativeFlowDeliveryPort.kt:228`：空应答 = 旧 daemon，fail loudly） |
| 新手机 + 旧桌面，缺的是**增强**能力 | **静默退回旧行为**，不报错；残留行为写进 PR 兼容表，升级桌面后消失 | #503：没有 `pair.cancel.v1` 就不发撤回，取消后桌面仍可批准 |
| 无法得知能力（如被吊销的手机 hello 被拒） | 按应答形状判断，失败时给出通用连接失败提示 | #468「例外：被吊销过的手机」 |

每个动协议的 PR 都附一张「新旧两端兼容表」（#468 / #503 的格式），这张表就是 C 格的预期结果。

卡面 C 格原写「静默降级，不是报错轰炸」，与上表第二行（必需能力缺失时明确报错）有出入，见 **D2**。

## 5. 降级与回滚

| 场景 | 现状行为 | 依据 |
|---|---|---|
| 桌面装回旧版本，而新版本已跑过新迁移 | 旧 daemon 拒绝启动（sqlx 报 `previously applied but is missing`）；桌面壳显示原文 +「请装回新版本」。数据不被改写，装回新版即恢复 | E2（DESK-09 真机欠账 #103）；2026-08-25 真机现场见 `cards/DESK-09-wizard-swallows-daemon-startup-error.md` |
| 桌面装回旧版本，两版之间没有新迁移 | 旧 daemon 能开库；协议层按 §4 旧端对新字段宽容 | 读码（未演练） |
| 桌面安装包本身是否拦截降级安装 | 未验证 | — |
| Android 装回旧 APK | 系统拒绝低 versionCode 覆盖安装，只能先卸载；卸载会清掉 `pairing.json`、`identity.key` 与账本，等于重新配对 | 读码（Android 平台规则） |
| Android 账本遇到更高的 `user_version` | `onDowngrade` 同样删表重建 | 读码 |
| 「manifest 指回旧版 = 回滚」 | **不成立**：客户端只在候选版本严格更新时提示（`isNewer` / `is_newer`），且 `bump-version.sh` 不允许复用或回退版本号。能做到的是「用更高版本号重新发布旧代码」（前滚式回滚） | E2 |

是否承诺可回滚见 **D4**。

## 6. 待拍板

| 编号 | 问题 | 选项 A | A 的代价 | 选项 B | B 的代价 |
|---|---|---|---|---|---|
| D1 | 升级支持跨几个版本 | 从起算版本（建议 `v0.6.0-test.2`）起，任意已发布版本直升最新 | 每次发版 A/B 格要从最老基线跑一遍；Android 账本遇到多次 schema 变更时 D5 的代价叠加 | 只承诺相邻版本（N-1 → N） | 跳版本的用户没有保证，而测试版用户常跳版本；目前也没有「先升到中间版本」的引导机制 |
| D2 | 错配时新端缺必需能力：报错还是降级 | 明确报错（#468 / NET-24 现行做法） | 错配期间该功能直接不可用，用户要先升另一端；卡面 C 格措辞要改成「一次性明确报错，不重试不刷屏」 | 降级兼容旧端 | 旧路径的限制原样带回（#468 的例子：要在 `DaemonClient` 加分钟级超时档，等于把刚拆掉的焊点搬回来）；每个新能力都要写并测试一套降级路径 |
| D3 | 两端错配承诺互通到多远 | 相邻版本互通；更远只保证「明确报错、不损数据」 | 用户半年不升一端可能被挡；矩阵 C 格只测 N-1 ↔ N 两种组合 | 同一 `PROTO_VER` 内全部互通 | 能力位只增不删、旧路径永久保留，代码与测试持续膨胀；C 格组合数随版本数增长 |
| D4 | 是否承诺可回滚 | 不承诺装回旧版；回滚 = 以更高版本号重新发布旧代码 | 线上出事时止血要走一次完整发版流程；E 格改为演练「前滚式回滚」，并验证 DESK-09 提示 | 承诺可装回上一个已发布版本 | 桌面：迁移须只加不改，并让旧程序容忍未知迁移（sqlx 目前默认拒绝）；Android：系统层面必须卸载，需要先做配对/身份的备份导出，属于新工作 |
| D5 | Android 账本 schema 升级怎么处理 | 继续删表重建（现状） | schema 升级后丢 `skip_list`（用户跳过的照片会重新进备份）与未送达的审计事件；首轮要全量对账扫描。照片本身不会重复入库 | 从 v3 起写真迁移 | 每次 schema 变更都要写迁移代码和「旧库 → 新代码」测试；#429 已立的「新列进 CHECK + 升版本」惯例要补上迁移步骤 |
| D6 | 测试版与正式版之间的兼容边界 | 承诺只覆盖正式版之间；test 版之间尽力而为 | 正式版从未发布，而狗粮用户全在 test 通道，承诺现在对任何人都不生效 | test tag 与正式版同等承诺 | 每个 test tag 都要跑完矩阵，发版节奏变慢；test → stable 切换时停在较新 test 版的行为也要纳入承诺 |

## 7. 矩阵与条款对照

| 格 | 验证的条款 | 已有结果（#432 评论） | 缺口 |
|---|---|---|---|
| A Android 升级 | §2 Android 路径；§3 手机侧各行；D1、D5 | 模拟器两轮：完成态与传输中途态覆盖安装，配对、相册范围、账本行数、续传均保留 | 非发布签名包；没覆盖「已传部分字节的大文件」中途态；账本 schema 升级路径（D5）没有可验的版本；手机 `identity.key`、设置文件未逐项比对 |
| B 桌面升级 | §2 桌面路径；§3 桌面侧各行；D1 | Windows 真机两轮全绿，诊断包可导出（DESK-40 [#483](https://github.com/hawkeye-xb/P-Pass/issues/483) 已修） | macOS 未跑；第二轮没有新迁移可验 |
| C 版本错配 | §4.2 各行；D2、D3 | 两种错配组合配对/备份/浏览全通 | 两版本之间没有不兼容点，报错/退回行为无场景可验；现有依据只有 JVM 用例（`NET10PairPollTest` 旧桌面无能力、`DEV07PairCancelTest` 无 `pair.cancel.v1` 不发） |
| D 通道语义 | §2 通道行；`docs/RELEASING.md` §3.6；D6 | — | 挂起：等首个正式 tag |
| E 回滚 | §5；D4 | 未做 | 卡面口径「manifest 指回旧版 = 回滚」按 §5 不成立，需先按 D4 改写 |
