# 升级兼容承诺（REL-06）

> **已定稿**（D1–D6 由验收人 2026-09-30 拍板，[#587](https://github.com/hawkeye-xb/P-Pass/issues/587) 收口成文）：本文是「老版本 → 新版本」时 P-Pass 保证什么的唯一事实源，也是 [#432](https://github.com/hawkeye-xb/P-Pass/issues/432) 验证矩阵的判据。

本文回答「老版本 → 新版本」时 P-Pass 保证什么。它是 #432 验证矩阵的判据：每一格验的是下面某一条承诺。
「依据」一列：E2 / E3 沿用 AGENTS.md 的证据分级（E2 contract 测试、E3 真机真环境）；「读码」表示只有代码阅读，没有测试或实跑。

## 0. 口径

| 术语 | 含义 |
|---|---|
| 版本 | **已打 tag 并发布的 release**（`v<X.Y.Z>[-test.N]`，`docs/RELEASING.md` §1）。两个 tag 之间的本地构建版本串可能相同（#432 评论：main 与 test.2 同为 `0.6.0-test.2`），不在承诺范围内 |
| 可独立更新的单元 | 只有两个：**桌面（含 daemon）**、**Android**。daemon 作为 sidecar 随桌面包分发，不存在单独升级 daemon 的场景 |
| 发布侧单元 | 更新通道 / manifest（`docs/RELEASING.md` §3.5、§3.6） |
| 相邻版本 | 同一通道里按发布顺序紧挨着的两个 tag |

当前基线（2026-10-04 更新）：首个正式版已发布（`v0.8.4`，stable 通道 manifest 已活）；更早的 test tag 与 release 已于 2026-10-04 清理，仓库现存 `v0.8.4` + 两个滚动 prerelease（`dogfood` / `test-channel`）。承诺的历史起算点见 §2「起算版本」——早于它的安装包在 GitHub 上已不可下载，只剩存量狗粮机上的在跑实例。

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
| 版本跨度 | — | **D1（已定）**：只前进、任意直升——从起算版本起的任意已发布版本，直接升到最新；不支持降级（见 §5） | A、B |
| 起算版本 | — | 从 `v0.6.0-test.2` 起算：更早的版本升到 #413 之后，`flow-state/` 旧账本会被一次性删除（见 §1），不属于平滑升级 | A、B |
| 两端错配 | 手机与桌面各自升级 | 见 §4；互通范围按 **D3（已定）**：只承诺**相邻版本**互通；更远只保证「明确报错、不损数据」 | C |
| test ↔ stable 通道 | 设置页切换 | 当前 test 版比 stable 新时切到 stable 不会提示「更新」（`isNewer` 严格大于），会停在 test 版直到 stable 追上；边界按 **D6（已定）**：test 版与正式版同受本文件承诺约束 | D |

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
| 备份账本（order 状态、跳过名单、审计 outbox） | `databases/backup-orders.db` | schema 版本不变时原样保留；**schema 升级时删表重建** | **D5（已定）**：测试阶段（public beta 之前）允许删表重建——此时能保证的只有照片不重复入库（桌面按内容哈希去重），`skip_list` 与未送达的 `audit_outbox` 不保证保留；**public beta 之后禁止删表重建**：schema 变更必须写真迁移，并配「旧库 → 新代码」的迁移测试（见 §6 D5 与 §7） | A：只验过 schema 不变的情况（3 → 3，行数 26/0/26/1/3 不变） |
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

**D2（已定）**：错配时新端缺必需能力 = **明确报错**（#468 / NET-24 现行做法即定稿）——一次性提示升级另一端，不重试、不刷屏、不写降级路径。卡面 C 格原写「静默降级，不是报错轰炸」，按 D2 收口为：**C 格的通过口径 = 必需能力缺失时一次性明确报错；增强能力缺失时静默退回旧行为**（上表两行）。「不刷屏」保留：报错一次性，不重试轰炸。

## 5. 降级与回滚

| 场景 | 现状行为 | 依据 |
|---|---|---|
| 桌面装回旧版本，而新版本已跑过新迁移 | 旧 daemon 拒绝启动（sqlx 报 `previously applied but is missing`）；桌面壳显示原文 +「请装回新版本」。数据不被改写，装回新版即恢复 | E2（DESK-09 真机欠账 #103）；2026-08-25 真机现场见 `cards/DESK-09-wizard-swallows-daemon-startup-error.md` |
| 桌面装回旧版本，两版之间没有新迁移 | 旧 daemon 能开库；协议层按 §4 旧端对新字段宽容 | 读码（未演练） |
| 桌面安装包本身是否拦截降级安装 | 未验证 | — |
| Android 装回旧 APK | 系统拒绝低 versionCode 覆盖安装，只能先卸载；卸载会清掉 `pairing.json`、`identity.key` 与账本，等于重新配对 | 读码（Android 平台规则） |
| Android 账本遇到更高的 `user_version` | `onDowngrade` 同样删表重建 | 读码 |
| 「manifest 指回旧版 = 回滚」 | **不成立**：客户端只在候选版本严格更新时提示（`isNewer` / `is_newer`），且 `bump-version.sh` 不允许复用或回退版本号。能做到的是「用更高版本号重新发布旧代码」（前滚式回滚） | E2 |

**D4（已定）**：不承诺装回旧版本。**回滚 = 以更高版本号重新发布旧代码**（前滚式回滚，§5 的「manifest 指回旧版」本来就不成立）。线上出事的止血路径：发一个版本号更高的「旧代码重发版」，客户端按严格更新规则正常前进。

## 6. 已定稿：D1–D6（2026-09-30 验收人拍板）

| 编号 | 定稿 | 落点 |
|---|---|---|
| D1 | **跨版本：只前进、任意直升**。从起算版本起的任意已发布版本直接升到最新；不为跳版本用户设中间站 | §2「版本跨度」 |
| D2 | **错配缺必需能力 = 明确报错**：一次性提示升级另一端，不重试、不刷屏、不写降级路径；增强能力缺失仍可静默退回旧行为 | §4.2（C 格口径随之改写） |
| D3 | **错配互通只承诺相邻版本**（N-1 ↔ N）；更远只保证「明确报错、不损数据」 | §2「两端错配」、§4.2 |
| D4 | **不承诺装回旧版本**；回滚 = 以更高版本号重新发布旧代码（前滚式回滚） | §5 |
| D5 | **Android 账本 schema：public beta 前允许删表重建**（现状）；**public beta 后禁止删表**——schema 变更必须写真迁移，并配「旧库 → 新代码」迁移测试 | §3「备份账本」行 |
| D6 | **test 版与正式版同受本文件承诺约束**；升级验证进 CI/CD，作为发版流水线的一环（哪些格子可自动化见 §7 末段） | §2「test ↔ stable 通道」 |

落选一侧的理由曾写在选项表里（2026-09-29 草案版，git 历史可查），此处只留定稿。

### 升级验证进发版流水线（D6 后半条）：哪些格子可以自动化

| 格 | 可自动化程度 | 进流水线的形状 |
|---|---|---|
| B 桌面升级（旧库 → 新包） | **可全自动**：旧版本 fixture 库（index.sqlite + originals 样本）+ 新代码打开 | 一个「旧库 fixture → 新代码跑迁移 + 对账」的 Rust 集成测试，固定在 ci-rust；fixture 版本在每次发版前更新 |
| A Android 升级 | **半自动**：JVM/模拟器侧（保留配对、范围、账本行数）可自动化；「已传部分字节的大文件中途升级」需要真机 | JVM 层进 ci-android；中途态留在真机回归清单 |
| C 版本错配 | **可全自动**：相邻版本的 hello 能力位 / 旧帧解析本来就是 JVM+快照用例 | 已在 ci-android / ci-rust（GoldenDriftTest、NET10PairPollTest 这类），随协议演进自然生长 |
| D 通道语义 | **可脚本化**：test/stable 的 manifest 指向与 isNewer 判定 | 发版后由管线断言脚本核对（stable 不收 test 包、test 通道指针前进不回退） |
| E 回滚 | **半自动**：前滚式回滚本身是发版动作（管线即代码）；DESK-09 提示的验证要真机 | 演练记录进发版 checklist，不追求每次发版都练 |

真机硬门（A 的中途态、E 的提示验证）进 `docs/runbook/live-acceptance-checklist.md`，不伪装成 CI。

## 7. 矩阵与条款对照

| 格 | 验证的条款 | 已有结果（#432 评论） | 缺口 |
|---|---|---|---|
| A Android 升级 | §2 Android 路径；§3 手机侧各行；D1、D5 | 模拟器两轮：完成态与传输中途态覆盖安装，配对、相册范围、账本行数、续传均保留 | 非发布签名包；没覆盖「已传部分字节的大文件」中途态；账本 schema 升级路径（D5）没有可验的版本；手机 `identity.key`、设置文件未逐项比对 |
| B 桌面升级 | §2 桌面路径；§3 桌面侧各行；D1 | Windows 真机两轮全绿，诊断包可导出（DESK-40 [#483](https://github.com/hawkeye-xb/P-Pass/issues/483) 已修） | macOS 未跑；第二轮没有新迁移可验 |
| C 版本错配 | §4.2 各行；D2、D3 | 两种错配组合配对/备份/浏览全通 | 两版本之间没有不兼容点，报错/退回行为无场景可验；现有依据只有 JVM 用例（`NET10PairPollTest` 旧桌面无能力、`DEV07PairCancelTest` 无 `pair.cancel.v1` 不发） |
| D 通道语义 | §2 通道行；`docs/RELEASING.md` §3.6；D6 | 首个正式 tag 已发（v0.8.4，2026-10-04） | D 格验证已可开跑：stable 通道绝不收 test 包 + 指针不回退，按上节「进流水线」表脚本化 |
| E 回滚 | §5；D4（已定：前滚式回滚） | 未做 | 按 D4 改写卡面 E 格口径：演练「以更高版本号重发旧代码」+ 验证旧库被新版迁移后旧程序的拒绝启动提示（DESK-09） |
