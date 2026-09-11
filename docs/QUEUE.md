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
> 最后核对：**2026-09-11**（历史提交与 current `main` 重新对账：所有分支已收拢，
> 但 MOB-62 在重新扫码场景出现新的主线程 ANR，已从归档重新打开；此前“代码完成、
> 等真机复核”的卡不再混入已完成区。）

---

## 〇、当前阶段背景（process，别重新摸索）

- **阶段**：真机回归驱动的修 bug 循环。代码侧健康（本机全绿），**卡住的
  是真机验收**，不是代码没写。
- **最新可测版本**：working tree 已 bump 到 `0.5.0-test.8`（2026-09-07 `e5d7a28`），
  已打 tag 到 `v0.5.0-test.7`；本行此前长期滞后写着 v0.4.0-test.9，2026-09-09
  核实修正——改版本号后务必同步这里，别让下次汇报又抄错。
- **本机全绿基线**：`just ci` all green · nextest 345 passed / 1 skipped ·
  Android 46 类 / 347 tests / 0 failures · 桌面 `pnpm test 58`（DESK-15
  新增 Button/Card 组件合同测试）+ `src-tauri cargo test --lib 18`。
  （2026-09-09 核实更新，此前长期滞后写着 320/24/15。）
- **环境事实**：验收人照片库 `~/Pictures/P-Pass 家庭照片库`（**真实数据，
  一个字节都不许碰**）；测试机三星 SM-S9210，**不许做 adb 写操作**；
  `gh` 未登录、仓库私有 → 看不到 Actions 结论，push 后要验收人自己扫 CI。
- **范围红线**：文件备份 / 文件同步整个不在范围内，**只做图片**。

---

UI-04a/UI-04c 仍待共享 Android 回归；UI-04b 已完成真实 Tauri 视觉验收并归档；
UI-08、BLOB-03 与 AUDIT-04 已通过归档。

---

## 一、进行中

（当前没有进行中的卡。）
---

## 二、待共享回归（代码已合并，就差你动手）

| 卡 | 一句话 | 级别 |
|---|---|---|
| [AUDIT-02](../cards/AUDIT-02-activity-record-meaningful-projection.md) | canonical evidence summary 已投影为「已备份 N 张照片」并过滤连接/控制噪音；待 current-main Desktop 隔离 Flow 真验 | L2 |
| [MOB-64](../cards/MOB-64-revoked-device-gets-no-feedback-until-next-attempt.md) | 三星真机撤销后实际收到 `err.not_authorized`，仍显示普通重试而非 pairingLost 红卡 | L2 |
| [UI-04a](../cards/UI-04a-interruption-notice-only-visible-on-home.md) + [UI-04c](../cards/UI-04c-multiple-notices-stack-without-priority.md) | 全局提示容器与最高优先级单条呈现（代码完成，待共享真机回归） | L2 |
| [UI-09](../cards/UI-09-aggregate-status-must-read-flow-ledger.md) | 在 MOB-51 同轮验收中，确认传完后 AllSafe 与「待备份 K」归零流转 | L2 |
| [NET-04](../cards/NET-04-connection-path-tracking-for-transfer-and-billing.md) | 三星真机 5 个 `NET04-test-e` 文件已全部 `CONFIRMED`；待回归 Pause / Cancel / 失败 Retry | L2 |
| [NET-05](../cards/NET-05-flow-data-path-status-follows-transfer-lifecycle.md) | 代码完成：active Flow 先显示连接中，随后显示 blobs 数据面直连/中继；待慢速传输及 Pause/Cancel/失败真机回归 | L2 |
| [MOB-26](../cards/MOB-26-photo-viewer-needs-real-library.md) | 页序、Telephoto 缩放/下拉关闭、系统返回层级 | L2 |
| [UX-14](../cards/UX-14-a-failed-retry-is-rendered-as-paused.md) | 暂停 → 继续 → 中断连接；界面不许又显示「继续」，应如实显示待备份或错误 | L1 |
| [DESK-10](../cards/DESK-10-export-logs-omits-the-only-logs-that-matter.md) | 正常 daemon 可达包已通过；不可达分支必须由 agent 以隔离故障环境实证，不能要求验收人造故障 | L1 |
| [WATCH-07](../cards/WATCH-07-self-inflicted-duplicate-audit-noise.md) | 备份后活动流不再被「重复」审计刷屏 | L2 |
| [MOB-13](../cards/MOB-13-triplet-k-never-reaches-zero.md) | 「待备份 K」能归零（有前置，见卡） | L2 |
| [E2E-02](../cards/E2E-02-daemon-hello-test-asserts-dead-contract.md) | e2e 门禁已解红，下次打 tag 复核 | L1 |
| [I18N-01](../cards/I18N-01-unnamed-album-fallback-is-hardcoded-chinese.md) | 英文系统下空相册名显示 Unnamed | L3 |
| [DESK-09](../cards/DESK-09-wizard-swallows-daemon-startup-error.md) | 旧 daemon 打开新版库时向导显示真实 stderr 与升级提示 | L1 |
| [MOB-60](../cards/MOB-60-cancel-round-leaves-stale-pause.md) | 取消当前轮完成后必须落 Idle，不显示暂停/继续/取消 | L1 |
| [DESK-13](../cards/DESK-13-ingest-blocks-tokio-runtime-freezes-desktop-ui.md) | 大文件/视频传输时桌面照片墙与暂停/取消不应冻结 | L0 |
| [MOB-57](../cards/MOB-57-pause-cancel-buttons-lack-pending-state.md) | 暂停/取消连点只接受一次命令并有处理中反馈 | L1 |
| [UI-10](../cards/UI-10-flow-runtime-blindness-and-legacy-ui-tails.md) | epoch 自愈、重传提示、归属过滤与失联提示的组合回归 | L3 |
| [DESK-11](../cards/DESK-11-flow-ingest-not-live-in-library-view.md) | Flow 摄入后桌面库实时出现照片 | L1 |
| [DESK-12](../cards/DESK-12-flow-ingest-loses-capture-date.md) | Flow 摄入保留照片拍摄日期而非归入当月 | L1 |
| [MOB-56](../cards/MOB-56-unsynchronized-delivery-callbacks-race-strict-head.md) | 并发失败/收据回调不触发同一队头双发 | L0 |
| [MOB-54](../cards/MOB-54-transient-failure-does-not-auto-retry.md) | 临时失败后队列自动重试并继续后续项 | L1 |
| [MOB-53](../cards/MOB-53-legacy-confirmed-items-missing-completedat.md) | 旧账本已确认项补 completedAt，首页不再永久显示从未成功 | L1 |

**已有真机证据的**（2026-08-21 审计，仅供复核）：MOB-30、WATCH-02。

**验收建议**：15 分钟一批过，别攒。

---

## 三、可接队列（无阻塞，可以直接分给任何 agent）

| 优先级 | 卡 | 一句话 | 级别 |
|---|---|---|---|
| P2 | [NET-03](../cards/NET-03-idle-phone-floods-audit-with-connection-events.md) | 手机闲置时审计被连接事件刷屏——先取证定性真抖动 vs 误记 | L2 |
| P0 | [MOB-62](../cards/MOB-62-unpair-must-reset-flow-runtime-and-wakes.md) | 断开后重扫再次触发主线程 ANR：状态读取懒创建 native runtime，必须移出 UI 线程 | L2 |
| P3 | [BUILD-01](../cards/BUILD-01-local-jdk25-breaks-release-lint.md) | 本机 JDK 25 让 Android release 构建挂 lint；CI 钉 17 不受影响 | L3 |
| P3 | [UI-04d](../cards/UI-04d-reupload-notice-uses-failure-channel.md) | 重传通知挂在「失败」渠道下，分类名不对 | L2 |
| P3 | [REL-04](../cards/REL-04-manifest-url-decided-before-mirror-succeeds.md) | manifest 地址在镜像成功前就写死 | L2 |
| P3 | 未开卡 | 活动流把机器原文直接显示给用户，需改文案 | L2 |
| P3 | [UI-07](../cards/UI-07-wrong-small-icon-has-no-lightning-mark.md) | 小 icon 用错版本，等验收人给修改指示 | L3 |
| P3 | [MOB-66](../cards/MOB-66-android-brand-font-newsreader-manrope.md) | Android 端标题/正文仍是系统默认字体，未接 Newsreader/Manrope，与桌面品牌不一致 | L2 |
| P2 | [MOB-69](../cards/MOB-69-rebuild04-deleted-notification-senders.md) | REBUILD-04 批次删除带走哨兵/白名单/重传三条通知发送端（判定逻辑成死代码）；先定性再接线或显式下线 | L2 |

---

## 四、待你复现或拍板（agent 不许编码）

| 卡 | 一句话 | 当前等待 |
|---|---|---|
| [NET-01](../cards/NET-01-backup-begin-times-out-for-15s-then-backs-off.md) | 三星热点大视频已复现 `flow.fetch` 15 秒超时；不能靠小文件成功掩盖 | **等可持续的蜂窝热点 / relay 窗口后再改并跑大视频回归** |
| [MOB-52](../cards/MOB-52-oppo-bg-wake-fail-and-launch-crash.md) | OPPO Reno8 后台不触发上传 + 点开 App 闪退（L0） | **等崩溃证据**，拿不到不编码 |
| [AUDIT-01](../cards/AUDIT-01-flow-audit-v2-durable-outbox.md) | `audit_event` v2 已被 AUDIT-04 canonical 四表直接替换 | **冻结**；不验旧 UI，不恢复旧模型 |
| [AUDIT-05](../cards/AUDIT-05-dogfood-week-audit-content-review.md) | 狗粮周后只读复核真实审计内容，验证既定预设的覆盖与字段关联 | **等狗粮周样本**；不阻塞 AUDIT-02 的首版 UI |
| [OBS-01](../cards/OBS-01-telemetry-privacy-consent-and-control.md) | 遥测默认 opt-out 且无 App 内隐私说明页/可见开关，承诺（手册+技术可行性报告）未兑现；[OBS-02](../cards/done/OBS-02-telemetry-event-dictionary-usefulness-review.md) 已裁决字典 v2，TEL-01~04 均已落地，当前仅自建自用，暂不算合规危机但欠账真实 | 字段列表已定，可以设计隐私页/开关 UI |

---

## 五、已完成 / 已归档（历史，非待办）

| 卡 | 结果 | 已释放 |
|---|---|---|
| [MOB-68](../cards/done/MOB-68-optional-permissions-map-to-backup-settings.md) | 首装按“媒体范围 → 点进入 App → 电池白名单 → 通知权限 → 首轮传输”串行；后台备份开关移入备份设置，开关后台行为已三星真机通过 | MOB-67 独立处理真实失败系统通知 |
| [MOB-61](../cards/done/MOB-61-deleted-phone-source-must-skip-not-retry-or-crash.md) | 三星真机：Flow 入队后删源 → `SKIPPED_SOURCE_MISSING` / `MISSING` / `UNRECOVERABLE`，lease 清空；后续项 2 秒确认，首页只读跳过提示无重试动作 | 无——缺源不再走失败重传或崩溃 |
| [MOB-67](../cards/done/MOB-67-notify-on-failure-switch-never-sends-notification.md) | 三星真机：开关开时第三次真实失败发固定 id 2027 系统通知；关时同一终态仍落账本但通知栏无 P-Pass 通知 | 无——失败通知开关不再是死开关 |
| [MOB-70](../cards/done/MOB-70-flow-ingest-moves-staging-source-before-metadata.md) | 三星 72 MB 视频确认：同手机 retry 按 peer 串行，避免并发 fetch 删除同一 staging 源 | 无——大文件不再三次重试终态失败 |
| [AUDIT-03](../cards/done/AUDIT-03-audit-contract-case-matrix.md) | 审计 Case Matrix、【本地】/名称+短指纹、支持级可信、全库保留与无专用导出边界均已收口 | 释放 AUDIT-04 审计核心重建 |
| [TEL-01](../cards/done/TEL-01-telemetry-dictionary-v2-schema.md) | 遥测字典 v2 落地：`conn` 删 ipver/country/isp_hash，`backup_session`→`flow_item` 精简字段，新增 `error`；daemon+Worker 同步改，`cargo test` 5/5 + `npm test` 14/14 + `just ci` 全绿 | 释放 TEL-02/03/04 接线卡 |
| [TEL-02](../cards/done/TEL-02-wire-conn-and-flow-item-events.md) | conn/flow_item 已接线 `flow_delivery.rs::fetch()`；顺带修正 TEL-01 遗留的 conn.path 枚举值（lan 不存在，改为 direct/relay/offline/unknown）；`cargo test -p daemon --test flow_delivery` 10/10、nextest 356/356、just ci 全绿 | 释放 TEL-03/04 的 TEL-01 依赖已满足 |
| [TEL-04](../cards/done/TEL-04-wire-first-byte-event.md) | first_byte 已接线 `query.rs::thumb()`/`original()`（仅成功交付字节的路径记录）；新增 `query_telemetry.rs` 3 个测试；nextest 359/359、just ci 全绿 | 释放 TEL-03 |
| [TEL-03](../cards/done/TEL-03-error-event-taxonomy.md) | error 事件已接线：`DeliveryError` 细分 8 个固定 code（Materialize 拆三个子系统变体）+ stage=offer/fetch/cancel；GuardMismatch/Cancelled 不上报（正常控制流非问题）；Telemetry 加 5min 去重窗口（同 code+stage 只记一次）；`cargo test --lib telemetry` 6/6 + `--test flow_delivery` 13/13、nextest 365/365、just ci 全绿 | 遥测五件套（daemon_alive/conn/flow_item/first_byte/error）全部闭环 |
| [DESK-14](../cards/done/DESK-14-overlay-titlebar-drag-area-is-too-small.md) | macOS 真机 2026-09-10：32px 透明顶部拖拽区正常；顺带发现并修复原生标题文字与侧栏品牌重复显示（加 `hiddenTitle: true`） | 无——拖拽区与标题重复均已闭环 |
| [DESK-15](../cards/done/DESK-15-desktop-design-system-convergence.md) | macOS 真机 2026-09-10：Button/Card/Dialog/Notice/NavItem 五组件在真实 Tauri 窗口视觉正常、无错位闪烁 | 无——五组件收口验收关闭 |
| [UI-04b](../cards/done/UI-04b-rename-feedback-uses-layout-occupying-banner.md) | 验收人 2026-09-10 确认：改名反馈改用 shadcn-svelte 官方 Sonner，右上角不占布局；成功/等待/错误映射 safe/waiting/act 三态色 | 无——手写 Toast/Message 已删除，通知呈现统一收口为官方原语 |
| [MOB-63](../cards/done/MOB-63-pause-racing-final-completion-must-set-idle.md) | 三星真机 2026-09-10：暂停与最后完成回执交错的两种时机均收敛 Idle | 无——竞态收敛已闭环 |
| [MOB-65](../cards/done/MOB-65-auto-backup-switch-must-not-pause-current-round.md) | 三星真机 2026-09-10：传输中关闭自动备份不中断当前轮，仅停止后续自动唤醒，重新打开恢复自动 | 无——自动开关与轮次暂停解耦已闭环 |
| [SYNC-05](../cards/done/SYNC-05-asset-meta-src-device.md) | `AssetMeta.src_device` 已经由 daemon 映射到线上协议；PhotosScreen 只按该字段和本机 NodeId 分类，未知来源只在「全部」显示 | 无——本地 `backup-state`/`flow-state` 归属影子状态及 fallback 已删除；Rust 全量、Android JVM 314/0/0/4 均绿 |
| [MOB-40](../cards/done/MOB-40-backup-runs-before-the-user-picks-albums.md) | 三星真机 2026-09-09 实证：扫码配对到选相册之间零传输迹象（通知/进度/流量均无）；选相册后正常同步 | 无——闸门生效，L0 红线关闭 |
| [MOB-38](../cards/done/MOB-38-foreground-catchup-never-fires-on-resume.md) | 三星真机 2026-09-09 多次复现：切出 App 再切回，无需任何点击即自动发起并完成传输 | 无——回到前台补捞已闭环 |
| [MOB-49](../cards/done/MOB-49-cancellation-round-never-clears-in-production.md) | 三星真机 2026-09-09：取消当前轮后 UI 恢复正常操作，不再永久卡在「已取消」文案 | 无——与 MOB-50 同轮组合验收完成 |
| [MOB-50](../cards/done/MOB-50-upload-cursor-stuck-after-cancel-round.md) | 三星真机 2026-09-09：取消轮后新增照片无需 ADB/重启即被正常发现、传输、确认 | 无——upload cursor 复位已闭环 |
| [UX-13](../cards/done/UX-13-no-resume-affordance-after-pause.md) | 三星真机 2026-09-09：暂停后按钮原地变「继续」，多轮暂停/继续验证正常，最终跑完全部备份 | 无——续传入口已闭环 |
| [MOB-51](../cards/done/MOB-51-hero-pause-not-sticky-across-round.md) | 三星真机 2026-09-09：连续备份多张照片全程可点「暂停」，与 MOB-49/50 组合验收完成 | 无——英雄区粘性已闭环 |
| [UI-08](../cards/done/UI-08-album-picker-long-name-wraps-and-thumb-blurry.md) | 验收人 2026-09-09 确认：长名称呈现与缩略图清晰度均通过 | 无——选相册视觉缺陷关闭 |
| [MOB-47](../cards/done/MOB-47-video-preview-in-viewer.md) | 验收人 2026-09-09 确认双端视频预览通过 | 无——视频查看器验收关闭 |
| [MOB-09](../cards/done/MOB-09-one-bad-media-record-kills-batch.md) + [MOB-19](../cards/done/MOB-19-manual-backup-same-bad-record-crash.md) | 旧批处理验收已被 Flow 生产路径取代；`BackupWorker` 仅 wake，缺源终态由 MOB-61 处理 | 无——不再让验收人构造旧 MediaStore 批处理故障 |
| [REL-06](../cards/done/REL-06-restore-v031-release-after-cleanup.md) | 验收人拍板：历史测试期 `v0.3.1` Release 产物无需恢复；保留 tag，现有 2 个资产维持现状 | 无——不下载/上传缺失资产，不改其他 Release |
| [SITE-03](../cards/done/SITE-03-backup-core-rebuild-story.md) | 中文工程复盘《为什么我们把备份核心整个换掉了》已发布；手写 sitemap 与 RSS 同步收录，Pages workflow `34102057353` 成功，线上三项均 200 | 无——文章只记录已公开 ARCH-01 / REBUILD 事实 |
| [MOB-58](../cards/done/MOB-58-cancel-round-no-feedback-no-restore-entry.md) | 三星真机 2026-09-07 两轮反馈：取消轮无常驻反馈+重复取消丢批次+进度条混用终身口径；`FlowRunner.restoreAllCancelledRounds()` 汇总恢复、`NoticeCard` 常驻入口（去 Discard 死路）、`advanceRoundProgress` 本轮独立 0 起算；JVM 298/0/4、just ci 均绿。2026-09-09 三星真机组合回归验证通过（顶部「重新传输」提示常驻可点，点击后继续完成备份） | 无——同时收敛 MOB-55（同一根因，取消存档），本卡关闭 |
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
| [DESK-15](../cards/done/DESK-15-desktop-design-system-convergence.md) | 暂缓，低优先级 | 2026-09-09 拍板：Button 组件缺「图标动作」(icon-only) 变体——验收标准列了，但目前代码没有真实调用场景，不凭空加；等出现实际需要图标按钮的页面时再补 |

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
