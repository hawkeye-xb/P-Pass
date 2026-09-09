# P-Pass 唯一待办队列

> **这是唯一的"现在该干什么"入口**，取代原来各写一半、状态会漂移的
> `docs/CHECKLIST.md` 和 `docs/HANDOFF-*.md`（已删除）。
>
> **规则**：本文件的每一条只能从 `cards/` 的卡片横幅"读出"，
> 不允许在这里加人工新判断——卡仍是唯一事实源，本文件只是它**唯一**的
> 对外索引。卡的状态变了，本文件必须跟着改（AGENTS.md「每批交付必更
> 文档」清单的一项）。
>
> 本机路径 / 设备 / 本地命令不在这里——它们在 `local-state.md`
> （开发机本地文件，不进 git）。
>
> 最后核对：**2026-09-08**（REL-06 按验收人决定归档、不恢复历史测试期 Release 资产；E2E-03/REL-05/BUILD-03/CI-04 逐条核实关闭；
> MOB-39/MOB-42/MOB-48/MOB-41 核实已被生产架构取代，关闭；DOG-03 用户拍板
> 不做；MOB-46 用户拍板不追；MOB-44 用户拍板删除——鸿蒙 NEXT 不支持后台运行；
> UI-04 按用户要求拆成 UI-04a~d 四张独立卡）

---

## 〇、当前阶段背景（process，别重新摸索）

- **阶段**：真机回归驱动的修 bug 循环。代码侧健康（本机全绿），**卡住的
  是真机验收**，不是代码没写。
- **最新可测版本**：working tree 已 bump 到 `0.5.0-test.8`（2026-09-07 `e5d7a28`），
  已打 tag 到 `v0.5.0-test.7`；本行此前长期滞后写着 v0.4.0-test.9，2026-09-09
  核实修正——改版本号后务必同步这里，别让下次汇报又抄错。
- **本机全绿基线**：`just ci` all green · nextest 320 passed / 1 skipped ·
  Android 46 类 / 347 tests / 0 failures · 桌面 `pnpm test 24` +
  `src-tauri cargo test --lib 15`。
- **环境事实**：验收人照片库 `~/Pictures/P-Pass 家庭照片库`（**真实数据，
  一个字节都不许碰**）；测试机三星 SM-S9210，**不许做 adb 写操作**；
  `gh` 未登录、仓库私有 → 看不到 Actions 结论，push 后要验收人自己扫 CI。
- **范围红线**：文件备份 / 文件同步整个不在范围内，**只做图片**。

---

## 一、进行中（已上云认领）

| 卡 | 一句话 | 分支 |
|---|---|---|

其余 UI-04a/UI-04b/UI-04c/UI-08 均已合入 `main`，转入下方共享回归队列。

---

## 二、待共享回归（代码已合并，就差你动手）

| 卡 | 一句话 | 级别 |
|---|---|---|
| [UI-04a](../cards/UI-04a-interruption-notice-only-visible-on-home.md) + [UI-04c](../cards/UI-04c-multiple-notices-stack-without-priority.md) | 全局提示容器与最高优先级单条呈现（代码完成，待共享真机回归） | L2 |
| [UI-04b](../cards/UI-04b-rename-feedback-uses-layout-occupying-banner.md) | 桌面改名反馈已改 fixed 浮层（代码完成），待共享桌面回归 | L2 |
| [UI-08](../cards/UI-08-album-picker-long-name-wraps-and-thumb-blurry.md) | 代码完成：长名称单行省略、封面按显示像素请求；待共享回归截图与清晰度实证 | L3 |
| [MOB-51](../cards/MOB-51-hero-pause-not-sticky-across-round.md) | 连续备份 ≥20 张，任意时刻首页都有「暂停」；暂停 → 继续 → 取消；同轮带过 MOB-49/50 | L1 |
| [MOB-61](../cards/MOB-61-deleted-phone-source-must-skip-not-retry-or-crash.md) | 入队后从系统相册删除隔离测试照片：App 不闪退、不重传，后续继续，展示只读跳过告知 | L2 |
| [MOB-62](../cards/MOB-62-unpair-must-reset-flow-runtime-and-wakes.md) | 本轮三星已过：主动断开→新串→立即授权→选相册，无 ANR/旧 offer；统一回归补“开始一轮新备份” | L2 |
| [UI-09](../cards/UI-09-aggregate-status-must-read-flow-ledger.md) | 在 MOB-51 同轮验收中，确认传完后 AllSafe 与「待备份 K」归零流转 | L2 |
| [NET-04](../cards/NET-04-connection-path-tracking-for-transfer-and-billing.md) | 三星真机 5 个 `NET04-test-e` 文件已全部 `CONFIRMED`；待回归 Pause / Cancel / 失败 Retry | L2 |
| [NET-05](../cards/NET-05-flow-data-path-status-follows-transfer-lifecycle.md) | 代码完成：active Flow 先显示连接中，随后显示 blobs 数据面直连/中继；待慢速传输及 Pause/Cancel/失败真机回归 | L2 |
| [MOB-26](../cards/MOB-26-photo-viewer-needs-real-library.md) | 页序、Telephoto 缩放/下拉关闭、系统返回层级 | L2 |
| [MOB-49](../cards/MOB-49-cancellation-round-never-clears-in-production.md) | 取消后 UI 回到暂停态；与 MOB-50 一起验证新增媒体完整发现、传输、确认 | L1 |
| [MOB-50](../cards/MOB-50-upload-cursor-stuck-after-cancel-round.md) | 取消后复位 upload cursor；与 MOB-49 一起验证新增媒体完整发现、传输、确认 | L1 |
| [UX-14](../cards/UX-14-a-failed-retry-is-rendered-as-paused.md) | 暂停 → 继续 → 中断连接；界面不许又显示「继续」，应如实显示待备份或错误 | L1 |
| [MOB-40](../cards/MOB-40-backup-runs-before-the-user-picks-albums.md) | **卸载重装 → 配对 → 只选 11 张相册 → 全程只传这 11 张**；选相册前一张也不许传 | L0 |
| [DESK-10](../cards/DESK-10-export-logs-omits-the-only-logs-that-matter.md) | **复验**：两种导出均含预期日志；整个 zip 不得含用户名 | L1 |
| [MOB-38](../cards/MOB-38-foreground-catchup-never-fires-on-resume.md) | 从 App 切到相机拍一张再切回来，照片自动传上去 | L0 |
| [UX-13](../cards/UX-13-no-resume-affordance-after-pause.md) | 暂停后原地变「继续」；杀 App 重开仍在；正常跑完自己消失 | L1 |
| [WATCH-07](../cards/WATCH-07-self-inflicted-duplicate-audit-noise.md) | 备份后活动流不再被「重复」审计刷屏 | L2 |
| [MOB-19](../cards/MOB-19-manual-backup-same-bad-record-crash.md) | 手动「再试一次」与自动备份是同一条管线 | L2 |
| [MOB-09](../cards/MOB-09-one-bad-media-record-kills-batch.md) | 一条坏相册记录不再炸掉整批备份（好坏同批仍待验） | L2 |
| [MOB-13](../cards/MOB-13-triplet-k-never-reaches-zero.md) | 「待备份 K」能归零（有前置，见卡） | L2 |
| [BLOB-01](../cards/BLOB-01-ingest-leaves-a-duplicate-in-the-blob-store.md) | 备份占盘不再翻倍（实测 2.05x → 1.00x） | L2 |
| [E2E-02](../cards/E2E-02-daemon-hello-test-asserts-dead-contract.md) | e2e 门禁已解红，下次打 tag 复核 | L1 |
| [I18N-01](../cards/I18N-01-unnamed-album-fallback-is-hardcoded-chinese.md) | 英文系统下空相册名显示 Unnamed | L3 |
| [DESK-09](../cards/DESK-09-wizard-swallows-daemon-startup-error.md) | 旧 daemon 打开新版库时向导显示真实 stderr 与升级提示 | L1 |
| [MOB-47](../cards/MOB-47-video-preview-in-viewer.md) | 桌面视频应直接播放且可降级缩略图；Android 有播放/seek 控制且退出无播放器泄漏 | L2 |

**已有真机证据的**（2026-08-21 审计，仅供复核）：MOB-30、WATCH-02。

**验收建议**：15 分钟一批过，别攒。

---

## 三、可接队列（无阻塞，可以直接分给任何 agent）

| 优先级 | 卡 | 一句话 | 级别 |
|---|---|---|---|
| P1 | [BLOB-02](../cards/BLOB-02-flow-blobs-store-never-reclaimed.md) | 新 Flow 收件仓 `.ppf/flow-blobs` 无回收逻辑，占盘随传输量持续膨胀（实测已到数 GB） | L2 |
| P2 | [NET-01](../cards/NET-01-backup-begin-times-out-for-15s-then-backs-off.md) | 根因链已闭合（relay 15s 超时→backup.begin 从未送达）；下一步等 OPPO Reno8 真机 logcat 交叉验证 | L2 |
| P2 | [NET-03](../cards/NET-03-idle-phone-floods-audit-with-connection-events.md) | 手机闲置时审计被连接事件刷屏——先取证定性真抖动 vs 误记 | L2 |
| P2 | [DESK-14](../cards/DESK-14-overlay-titlebar-drag-area-is-too-small.md) | macOS Overlay 隐藏传统标题栏后，主界面与首启向导只有零碎拖拽空白；补连续顶部拖拽带且不吞交互 | L3 |
| P2 | [MOB-63](../cards/MOB-63-pause-racing-final-completion-must-set-idle.md) | 暂停恰逢最后一张完成：检测到轮次已清空后直接归位 Idle；正常有待传项的暂停仍保留「继续」 | L1 |
| P3 | [SYNC-05](../cards/SYNC-05-asset-meta-src-device.md) | AssetMeta 补来源设备字段，消灭客户端影子状态 | L1 |
| P3 | [BUILD-01](../cards/BUILD-01-local-jdk25-breaks-release-lint.md) | 本机 JDK 25 让 Android release 构建挂 lint；CI 钉 17 不受影响 | L3 |
| P3 | [UI-04d](../cards/UI-04d-reupload-notice-uses-failure-channel.md) | 重传通知挂在「失败」渠道下，分类名不对 | L2 |
| P3 | [LINT-01](../cards/LINT-01-android-lint-not-in-ci.md) | Android lint 不在 CI 里跑 | L3 |
| P3 | [CI-02](../cards/CI-02-e2e-compiles-release-binaries-twice.md) | e2e nightly 两个 job 各自编译一遍 release 二进制 | L3 |
| P3 | [REL-04](../cards/REL-04-manifest-url-decided-before-mirror-succeeds.md) | manifest 地址在镜像成功前就写死 | L2 |
| P3 | 未开卡 | 活动流把机器原文直接显示给用户，需改文案 | L2 |
| P3 | [UI-07](../cards/UI-07-wrong-small-icon-has-no-lightning-mark.md) | 小 icon 用错版本，等验收人给修改指示 | L3 |

---

## 四、待你复现或拍板（agent 不许编码）

| 卡 | 一句话 | 当前等待 |
|---|---|---|
| [MOB-52](../cards/MOB-52-oppo-bg-wake-fail-and-launch-crash.md) | OPPO Reno8 后台不触发上传 + 点开 App 闪退（L0） | **等崩溃证据**，拿不到不编码 |

---

## 五、已完成 / 已归档（历史，非待办）

| 卡 | 结果 | 已释放 |
|---|---|---|
| [REL-06](../cards/done/REL-06-restore-v031-release-after-cleanup.md) | 验收人拍板：历史测试期 `v0.3.1` Release 产物无需恢复；保留 tag，现有 2 个资产维持现状 | 无——不下载/上传缺失资产，不改其他 Release |
| [SITE-03](../cards/done/SITE-03-backup-core-rebuild-story.md) | 中文工程复盘《为什么我们把备份核心整个换掉了》已发布；手写 sitemap 与 RSS 同步收录，Pages workflow `34102057353` 成功，线上三项均 200 | 无——文章只记录已公开 ARCH-01 / REBUILD 事实 |
| [MOB-60](../cards/MOB-60-cancel-round-leaves-stale-pause.md) | 用户复测 MOB-58/59 追问坐实：取消当前轮完成后仍展示暂停/继续，点继续等于传空气；`FlowRunner.cancelCurrentRound()` 补 `continueFlow()` 归位闸门，取消完落到已有的 Idle 判断，不新增状态；JVM 298/0/4、just ci 均绿 | 无——闸门归位即完整闭环 |
| [MOB-58](../cards/MOB-58-cancel-round-no-feedback-no-restore-entry.md) | 三星真机 2026-09-07 两轮反馈：取消轮无常驻反馈+重复取消丢批次+进度条混用终身口径；`FlowRunner.restoreAllCancelledRounds()` 汇总恢复、`NoticeCard` 常驻入口（去 Discard 死路）、`advanceRoundProgress` 本轮独立 0 起算；JVM 298/0/4、just ci 均绿 | 无——同时收敛 MOB-55（同一根因，取消存档） |
| [DESK-13](../cards/DESK-13-ingest-blocks-tokio-runtime-freezes-desktop-ui.md) | 三星真机 2026-09-07 实证「桌面传输中不实时展示、手动刷新卡死很久」；`Ingestor::ingest()`/`place()` 大文件哈希/拷贝套 `block_in_place`（另一会话已埋的修复）+ 补齐 3 个测试文件的 multi-thread runtime flavor（此前配套缺失导致 24 个测试全 panic）；Rust 全绿、just ci 均绿 | 无——补测试闭环，真机复核大文件传输是否仍卡顿 |
| [MOB-57](../cards/MOB-57-pause-cancel-buttons-lack-pending-state.md) | 三星真机 2026-09-07 实证「暂停/取消连点几次后卡死」；暂停/取消按钮加 `commandPending` 重入守卫 + 禁用态/处理中文案；JVM 288/0/4、just ci 均绿 | [MOB-58](../cards/MOB-58-cancel-round-no-feedback-no-restore-entry.md)（"取消轮恢复传输"当时按 MOB-49 既定语义排除在外，后续用户明确要求才补上） |
| [UI-10](../cards/UI-10-flow-runtime-blindness-and-legacy-ui-tails.md) | 四项全做完：epoch 静默补齐（自愈优先于重新扫码）、重传提示换源账本 `NEEDS_DECISION`、照片页归属过滤换源、失联心跳接线；JVM 288/0/4、just ci、debug APK 均绿 | 无——四项均在本卡范围内闭环 |
| [DESK-11](../cards/DESK-11-flow-ingest-not-live-in-library-view.md) | 手机传完照片桌面不实时出现——`FlowDelivery` 补 `with_events`/throttle 接线（对齐 `BackupEngine` 既有模式）；Rust 336/336 passed、just ci 均绿 | 无——事件链闭环 |
| [DESK-12](../cards/DESK-12-flow-ingest-loses-capture-date.md) | 老照片桌面归错月——`taken_at_ms` 加 EXIF>capture_at_ms_hint>mtime 优先级，`FlowFetchRequest` 补 `capture_at_ms` 走 wire；Rust 336/336 passed、Android JVM 288/0/4、just ci 均绿 | 存量已错分照片未批量重刷，留给验收人真机确认后按需再开卡 |
| [MOB-56](../cards/MOB-56-unsynchronized-delivery-callbacks-race-strict-head.md) | 三星真机 2026-09-07 实证：两条并发传输失败日志相差 322ms；`onPermanentFailure`/`onReceipt` 补齐 `flowTriggerLock`（L0，违反 ARCH-03 单活跃租约不变量）；JVM 277/0/4、just ci 均绿 | 无——修复即完整闭环 |
| [MOB-54](../cards/MOB-54-transient-failure-does-not-auto-retry.md) | 三星真机 2026-09-07 实证：队尾照片卡在 QUEUED/attemptCount=1 传不完；`FlowRunner.recordPermanentFailure()` 补齐对称 `wake()`；JVM 276/0/4、just ci 均绿 | [MOB-55](../cards/MOB-55-cancel-current-round-tap-shows-no-feedback.md)（同一轮回归观察到的取消按钮无反馈，证据不足未合并处理）、[MOB-56](../cards/MOB-56-unsynchronized-delivery-callbacks-race-strict-head.md)（同一改动放大了一处早已存在的并发缺口） |
| [MOB-53](../cards/MOB-53-legacy-confirmed-items-missing-completedat.md) | 三星真机 2026-09-07 实证「37/38 已回家」+「从未成功备份过」永久矛盾；`DiscoveryLedgerStore.load()` 回填旧账本 CONFIRMED 项的 completedAt；JVM 275/0/4、just ci、debug APK 均绿 | 无——纯数据迁移，不产出下游卡；真机复核为可选项 |
| [REBUILD-05](../cards/done/REBUILD-05-flow-scope-expansion-backfill.md) | 三星真机自然复现迟到回执竞态并收敛为 `CONFIRMED`；范围扩展补扫全部验收标准完成 | 分出 MOB-49、MOB-50（取消本轮两处生产接线缺口） |
| [ARCH-02](../cards/ARCH-02-mobile-ledger-and-atomic-discovery.md) | D-01~D-04 账本/发现页原子提交完成 | ARCH-03 |
| [ARCH-03](../cards/ARCH-03-strict-consumer-pause-and-constraints.md) | C-01~C-05 严格消费者、Pause 与条件等待完成 | ARCH-04 |
| [ARCH-04](../cards/ARCH-04-completion-evidence-and-scope-revision.md) | E-01~E-04 完成凭据、范围竞争与 backfill 完成 | ARCH-05 |
| [ARCH-05](../cards/done/ARCH-05-cancellation-round.md) | X-01~X-05 取消本轮、恢复与丢弃完成 | ARCH-01 后续实施拆卡 |
| [ARCH-06](../cards/done/ARCH-06-pairing-epoch-isolation.md) | P-01/P-02 换 Desktop 的 epoch 隔离完成 | ARCH-01 P1 对账拆卡 |
| [ARCH-07](../cards/done/ARCH-07-remote-reconciliation-facts.md) | R-01/R-02 对账事实与恢复裁决完成 | ARCH-08 |
| [ARCH-08](../cards/done/ARCH-08-remote-presence-probe.md) | side-effect-free Desktop presence page 完成 | P1 分页选择 / 源探针 / 账本裁决接线卡 |
| [ARCH-09](../cards/done/ARCH-09-reconciliation-page-coordinator.md) | P1 账本分页、source probe 与 R-01/R-02 裁决协调完成 | 低频调度 / UI 卡 |
| [REBUILD-00](../cards/REBUILD-00-legacy-fence-and-flow-boundary.md) | `backup/flow` 边界、legacy 标记与旧测试三类分类完成 | REBUILD-01 / REBUILD-02 |
| [REBUILD-01](../cards/REBUILD-01-android-iroh-blobs-provider-bridge.md) | Android native blobs provider / JNI / debug APK 接线完成 | REBUILD-03 |
| [REBUILD-02](../cards/REBUILD-02-desktop-native-fetch-and-completion-receipt.md) | Desktop native fetch/resume 与 durable receipt 完成 | REBUILD-03 |
| [REBUILD-03](../cards/REBUILD-03-production-flow-runner.md) | Flow runner、trigger bridge、native receipt 接线完成 | REBUILD-04 |
| [REL-03](../cards/REL-03-bump-script-silently-skips-desktop-crate-version.md) | 批次 A：版本脚本版本目标全断言 | 批次 CI |
| [BUILD-02](../cards/BUILD-02-toolchain-pin-must-bind-on-ci-too.md) | 批次 A：五个 workflow 从 TOML 派生 Rust 工具链 | 批次 CI |

---

## 六、（原 ARCH-01 冻结区，2026-09-07 已清空）

> 原 MOB-39/MOB-42/MOB-48 三张卡：2026-09-07 复核确认 ARCH-01 + REBUILD-00~05
> 的生产切换已经落地并跑在生产上，这三张卡描述的旧 WorkManager/TriggerSpec
> 问题域在当前代码里已不存在（源码走查逐条核实：`BackupWorker` 已降级为纯
> framework wake adapter；`pauseAutoBackup` 已覆盖全部通道；`Pause`/`Continue`
> 语义已转移到 `backup/flow/` 的 `DiscoveryLedger`/`consumerGate`）。不是"待
> 重拆"，是已经被新架构解决，三张卡移入 `cards/done/`，不留在这里等待。
> 同批次一并核实关闭的还有 MOB-41（同一根因：点名的函数在生产代码里已零
> 调用，只剩单测引用旧 legacy 路径）。

---

## 七、ARCH-01 后续实施拆卡（按已收口边界开卡）

| 卡 | 覆盖 case | 当前等待 |
|---|---|---|
| [ARCH-01](../cards/ARCH-01-backup-core-flow-queue-design.md) | 后续拆卡边界 | ARCH-02~09 仅为未接生产骨架；REBUILD-00~04 执行生产切换 |

> self-review 已核对 case 覆盖、依赖顺序、范围与反证；ARCH-01 已定的产品语义不重开。
> ARCH-02、ARCH-03、ARCH-04、ARCH-05、ARCH-06 已完成；后续只可从 ARCH-01 的既定拆卡边界继续。

### 重建主线（唯一开发优先级）

| 阶段 | 卡 | 依赖 | 交付 |
|---|---|---|---|
| R0 | [REBUILD-00](../cards/REBUILD-00-legacy-fence-and-flow-boundary.md) | — | ✅ 旧线冻结、新 Flow 边界 |
| R1a | [REBUILD-01](../cards/REBUILD-01-android-iroh-blobs-provider-bridge.md) | R0 | ✅ Android blobs provider bridge |
| R1b | [REBUILD-02](../cards/REBUILD-02-desktop-native-fetch-and-completion-receipt.md) | R0 | ✅ Desktop fetch + completion receipt |
| R2 | [REBUILD-03](../cards/REBUILD-03-production-flow-runner.md) | R1a、R1b | ✅ 新生产 Flow runner |
| R3 | [REBUILD-04](../cards/done/REBUILD-04-worker-cutover-debug-apk.md) | R2 | ✅ 三星 Pause → kill → reopen → Continue → Cancel 通过 |
| R4 | [REBUILD-05](../cards/done/REBUILD-05-flow-scope-expansion-backfill.md) | R3 代码切换 | ✅ 三星真机自然复现迟到回执竞态，收敛为 `CONFIRMED` |
| R5 | [REBUILD-06](../cards/done/REBUILD-06-flow-offer-authz-after-scope-backfill.md) | R4 | ✅ completed receipt 的 recovered lease rebind 已在三星通过 |

---

## 八、backlog（明确不做或暂缓，agent 不许碰）

| 卡 | 状态 | 备注 |
|---|---|---|
| [MOB-07](../cards/MOB-07-partial-access-global-indicator.md) | 暂不做 | 2026-08-14 拍板 |
| [DOG-03](../cards/backlog/DOG-03-battery-whitelist-must-be-on-the-onboarding-path.md) | 明确不做 | 2026-09-07 用户拍板：不把「加电池白名单」做成 onboarding 必经步骤；根因（三星 Freecess 冻结看门 job）仍然成立，接受该场景下后台自动备份不工作 |
| WATCH-05 | 已拍板需要做，实施前重开讨论 | inode 身份缓存（stat 没变就不重算 hash） |
| WATCH-06 | 明确不做 | 卡里写明不要用软链物化视图 |
| MOB-25 | 暂不做 | 查看页尺寸显示 0×0，2026-08-19 拍板（MOB-26 已于 2026-08-27 解冻移回可接队列） |
| MOB-18 | superseded | 已被 MOB-28 取代，禁止按本卡实施 |
| DESK-11 | 待确认 | 🔵 backlog，若确认露出完整 hex 则升级为 DESK-10 的脱敏漏 |
| UI-05 / UI-06 | 用户暂时接受 | 展示细节问题，低优 |

---

## 九、发版现状（参考，非待办）

- 正式产物走 CI：`gh workflow run release.yml -f platforms=android,macos`
  （Android 出签名 APK；macOS 未签名，「右键 → 打开」过 Gatekeeper）。
- 调管线只用 workflow_dispatch，不打测试 tag（tag 纪律见 `AGENTS.md`）。
- **Secrets 实况（2026-08-25 核实）**：`CLOUDFLARE_API_TOKEN` /
  `CLOUDFLARE_ACCOUNT_ID` / `ANDROID_KEYSTORE_*` / `UPDATE_SIGNING_KEY` /
  `APPLE_*` 全部在位。
- **触发节奏**：ci-rust/ci-android/ci-desktop/site build 随 push（paths 门控）；
  e2e 走 nightly 03:30 + tag + PR 标签，也可 dispatch；artifacts（dogfood
  裸二进制）仅 Linux 自动，macOS/Windows 只手动；release 走 tag `v*` 或
  dispatch；ci-workers 随 infra/workers/** push 或 dispatch。
- **ci-workers 审批门**：`environment: workers-prod` 让部署 job 停在
  Waiting，不占 runner、不计费，挂 30 天自动作废。

---

## 十、相关文档指路

- 规则层（agent 无关）：[`AGENTS.md`](../AGENTS.md) + [`AGENT_PROTOCOL.md`](AGENT_PROTOCOL.md)
- 全量历史账本（只增不减）：[`ROADMAP.md`](ROADMAP.md)
- 方法论教训：[`PROGRESS.md`](PROGRESS.md)
- 交接背景日志（只读，不是待办来源）：[`NEXT.md`](NEXT.md)
- 卡格式规范：`cards/TEMPLATE.md` + `AGENT_PROTOCOL.md` §C.2
