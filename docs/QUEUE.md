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
> 最后核对：**2026-09-16**（三星真机跨网络（5G↔家庭WiFi）回归一轮：NET-01 补齐 relay 判决实验证据；MOB-71/MOB-76 各验证通过部分
> 核心场景并更新真机进度；新发现两张卡 MOB-85（三星
> MARs 策略绕过 NET-12 前台服务保护）、MOB-86（关闭后台备份总开关后排队
> 项失去全部唤醒路径），均入可接队列。此前一轮：用户反馈"进行中"卡挂僵尸——NET-06 讨论中拆出
> NET-14 处理后，NET-06 自身仍挂「进行中」但无人认领，导致下次对齐反复
> 撞见同一张卡。已按新增的 AGENTS.md「任务状态诚实与拆分纪律」全面整改：
> 「进行中」区清空为常态空表；NET-06 剩余 5 项验收缺口拆成独立子卡
> NET-15~19，各自可独立认领验收，完成后回写勾掉 NET-06 对应项，NET-06
> 待全部子卡归档后再一并归档；MOB-54 同样从「进行中」移入「可接队列」，
> 横幅注明当前无人认领。此前一轮：核对远端最近提交发现 DESK-12 卡内已标「已关闭」
> 但队列未同步，已挪入已完成区并移卡到 `cards/done/`。NET-14 同 WiFi 真机
> 冒烟通过，移入「待共享回归」等三星热点/relay/NET-12 长期存活三项硬门；
> 同轮真机会话新发现相册选择页渲染错乱开卡 MOB-84，入「可接队列」。上一轮
> 2026-09-15：
> NET-13 完成并本机真机验证通过：桌面设备
> 列表备份状态误报根因修复 + ID 列 + 打开目录 + 在线态独立列，移入
> 已完成。上一轮 2026-09-12：OPPO / v0.5.1 真机走查
> `docs/evidence/2026-09-12-oppo-051-dogfood.md`：新开 MOB-76；MOB-52/54/64/71/74
> 证据入账（MOB-54 真机复核失败重开定位）。上一轮 2026-09-11：真实狗粮新增
> MOB-71~75、UI-11；MOB-68 与 AUDIT-02
> 的既有“真机/真实数据通过”结论被新观察推翻，均已重新打开。所有描述均以卡片
> 横幅为准，不把 relay 限流等未证实推测写成根因。）

---

## 〇、当前阶段背景（process，别重新摸索）

- **阶段**：真机回归驱动的修 bug 循环。代码侧健康（本机全绿），**卡住的
  是真机验收**，不是代码没写。
- **最新可测版本**：`v0.5.1-test.1`（2026-09-12，含 test.7 之后的 MOB-62/64/71/72
  真机回归修复、AUDIT-02/04、BLOB-03、UI-04b）。上一轮 working tree 停在
  `0.5.0-test.8`（`e5d7a28`）但从未打 test.8 tag，已随 0.5.1 一并带上——
  改版本号后务必同步这里，别让下次汇报又抄错。
- **本机全绿基线**：`just ci` all green · nextest 345 passed / 1 skipped ·
  Android 46 类 / 347 tests / 0 failures · 桌面 `pnpm test 58`（DESK-15
  新增 Button/Card 组件合同测试）+ `src-tauri cargo test --lib 18`。
  （2026-09-09 核实更新，此前长期滞后写着 320/24/15。）
- **环境事实**：验收人照片库 `~/Pictures/P-Pass 家庭照片库`（**原始照片
  文件不许碰**；缩略图缓存 `.ppf/thumbs/`、`index.sqlite` 里可重新生成
  的派生字段如 `thumb_state` 属于派生数据，验证/调试时可以动，2026-09-14
  用户已明确拍板不用逐次确认）；测试机三星 SM-S9210，**不许做 adb 写
  操作**（截图/点击/App 生命周期控制/安装本身不算写操作）。
  `gh` 未登录、仓库私有 → 看不到 Actions 结论，push 后要验收人自己扫 CI。
- **范围红线**：文件备份 / 文件同步整个不在范围内，**只做图片**。

---

UI-04a 真机回归后用户反馈"状态不对"、具体点待用户说明，重新打开；UI-04b/UI-04c
已确认组件统一并归档；UI-08、BLOB-03 与 AUDIT-04 已通过归档。

---

## 一、进行中

| 卡 | 一句话 | 级别 |
|---|---|---|

> 空表是常态，不是漏填：本节只在**当前会话里真的有人在盯着改**时才填一行；
> 会话结束/转做别的卡后必须清空挪回下面对应分区，不许挂着「进行中」但无人
> 认领（AGENTS.md「任务状态诚实与拆分纪律」，2026-09-16 事故：NET-06 挂
> 「进行中」实际无人处理，导致下次对齐反复撞见同一张卡）。

---

## 二、待共享回归（代码已合并，就差你动手）

| 卡 | 一句话 | 级别 |
|---|---|---|
| [NET-14](../cards/NET-14-desktop-completion-must-push-not-poll-local-transfer-is-ground-truth.md) | 代码完成+同 WiFi 冒烟通过（证据：`docs/evidence/2026-09-16-net14-same-wifi-smoke.md`）；**待三星热点大视频跨 relay + 本地信号 idle 兜底 + NET-12 长期存活**三项真机硬门 | L2 |
| [NET-12](../cards/NET-12-flow-transfer-lacks-foreground-service-protection.md) | 三星真机实锤 2026-09-14 两次真实 killed（adj=900/915）：REBUILD-04 删除的前台服务保护已接回（`FlowTransferForegroundService` + `FlowTransferForeground.sync`），三星真机复测 adj 锁定在 200（不再降到 700-900 杀档），35 张全部 CONFIRMED；待长期真机回归观察 | L2 |
| [MOB-68](../cards/MOB-68-optional-permissions-map-to-backup-settings.md) | 后台备份以用户选择、标准白名单和 MediaWatch 健康三项裁决；通知权限不进 onboarding，后台异常仅在设置呈现；待 HarmonyOS 4.2 真机验证 | L2 |
| [UI-04a](../cards/UI-04a-interruption-notice-only-visible-on-home.md) | 两 tab 都能看到中断提示，但用户真机复核后反馈"状态不对"，待用户说明具体哪里不对 | L2 |
| [UI-09](../cards/UI-09-aggregate-status-must-read-flow-ledger.md) | 在 MOB-51 同轮验收中，确认传完后 AllSafe 与「待备份 K」归零流转 | L2 |
| [MOB-62](../cards/MOB-62-unpair-must-reset-flow-runtime-and-wakes.md) | Flow native 初始化不再持 runtime-map 锁；三星隔离图片 scope wake 已无 ANR，待完整断开重扫回归 | L2 |
| [MOB-72](../cards/MOB-72-scope-selection-must-wake-flow-without-relaunch.md) | 新增范围在后台原子 backfill + 当前约束 Flow wake；待三星取消轮后新相册不重启传输回归 | L2 |
| [MOB-76](../cards/MOB-76-wifi-only-constraint-must-block-cellular-transfer.md) | 代码完成：Wi-Fi 闸门改读实时网络（FlowRunner 6 处事件后 wake 硬编码放行 + Worker 调度放行误当业务闸门）；2026-09-16 三星真机验证前半支通过（限制开启+纯蜂窝→零传输+等待态），"连上 Wi-Fi 自动续传"待用真实网络切换补验证 | L1 |
| [MOB-71](../cards/MOB-71-paused-flow-must-not-show-wifi-wait-when-wifi-only-off.md) | 2026-09-16 三星真机验证核心场景通过（关闭限制后暂停/继续期间 Wi-Fi 等待不复活）；「重新开启限制后恢复等待提示」待补验证；09-12 OPPO 另见「重开再关限制不唤醒、需再选相册」并入回归 | L1 |
| [MOB-64](../cards/MOB-64-revoked-device-gets-no-feedback-until-next-attempt.md) | 真实 `err.not_authorized` 已与 `err.not_paired` 一并投影到 pairingLost 红卡；待三星重配对后撤销设备并验证下一次 Flow 调用。09-12 OPPO 入账：手机残留配对/桌面无记录时冷启动「尝试传输」长期零提示，拒绝码待取证 | L2 |
| [NET-04](../cards/NET-04-connection-path-tracking-for-transfer-and-billing.md) | 三星真机 5 个 `NET04-test-e` 文件已全部 `CONFIRMED`；待回归 Pause / Cancel / 失败 Retry | L2 |
| [NET-05](../cards/NET-05-flow-data-path-status-follows-transfer-lifecycle.md) | 代码完成：active Flow 先显示连接中，随后显示 blobs 数据面直连/中继；待慢速传输及 Pause/Cancel/失败真机回归 | L2 |
| [MOB-26](../cards/MOB-26-photo-viewer-needs-real-library.md) | 页序、Telephoto 缩放/下拉关闭、系统返回层级 | L2 |
| [DESK-10](../cards/DESK-10-export-logs-omits-the-only-logs-that-matter.md) | 正常 daemon 可达包已通过；不可达分支必须由 agent 以隔离故障环境实证，不能要求验收人造故障 | L1 |
| [WATCH-07](../cards/WATCH-07-self-inflicted-duplicate-audit-noise.md) | 备份后活动流不再被「重复」审计刷屏 | L2 |
| [E2E-02](../cards/E2E-02-daemon-hello-test-asserts-dead-contract.md) | e2e 门禁已解红，下次打 tag 复核 | L1 |
| [I18N-01](../cards/I18N-01-unnamed-album-fallback-is-hardcoded-chinese.md) | 空相册名兜底已本地化（纯函数+渲染合同 4 例测试齐），英文系统真机过一眼 | L3 |
| [DESK-09](../cards/DESK-09-wizard-swallows-daemon-startup-error.md) | 旧 daemon 打开新版库时向导显示真实 stderr 与升级提示 | L1 |
| [MOB-60](../cards/MOB-60-cancel-round-leaves-stale-pause.md) | 取消当前轮完成后必须落 Idle，不显示暂停/继续/取消 | L1 |
| [DESK-13](../cards/DESK-13-ingest-blocks-tokio-runtime-freezes-desktop-ui.md) | 大文件/视频传输时桌面照片墙与暂停/取消不应冻结 | L0 |
| [MOB-57](../cards/MOB-57-pause-cancel-buttons-lack-pending-state.md) | 暂停/取消连点只接受一次命令并有处理中反馈 | L1 |
| [UI-10](../cards/UI-10-flow-runtime-blindness-and-legacy-ui-tails.md) | epoch 自愈、重传提示、归属过滤与失联提示的组合回归 | L3 |
| [DESK-11](../cards/DESK-11-flow-ingest-not-live-in-library-view.md) | Flow 摄入后桌面库实时出现照片 | L1 |
| [MOB-56](../cards/MOB-56-unsynchronized-delivery-callbacks-race-strict-head.md) | 并发失败/收据回调不触发同一队头双发 | L0 |
| [MOB-53](../cards/MOB-53-legacy-confirmed-items-missing-completedat.md) | 旧账本已确认项补 completedAt，首页不再永久显示从未成功 | L1 |
| [UI-12](../cards/UI-12-notice-presentation-not-material-banner.md) | 后台备份降级状态已接入全局 `NoticeHost`；本轮追加 Snackbar 安全区适配（三键导航不再遮挡）+ 版本 bump `0.5.3-test.1`；三星真机复测开关/hint/横幅/授权同意拒绝分支全通过，378/378 JVM 绿；`SystemStoppedWatcher` legacy 判据未能真机复现已拆 MOB-81 backlog；待你鸿蒙 OPPO 二次核对 | L2 |
| [UI-13](../cards/UI-13-android-hand-rolled-widgets-not-material3.md) | tab 图标/角标/FilterChip/Button 改用 Material3 标准组件（`NavigationBar`/`ListItem` 因视觉冲突记录理由保留现状）；378/378 JVM 绿 + 三星真机截图确认视觉未走样；待你复核 | L2 |

**已有真机证据的**（2026-08-21 审计，仅供复核）：MOB-30、WATCH-02。

**验收建议**：15 分钟一批过，别攒。

---

## 三、可接队列（无阻塞，可以直接分给任何 agent）

| 优先级 | 卡 | 一句话 | 级别 |
|---|---|---|---|
| P0 | [MOB-54](../cards/MOB-54-transient-failure-does-not-auto-retry.md) | 三星 32 张相册停摆取证：当前没有 delivery failed，历史 cancel 已 restore；重放 receipt 与 discovery wake 交错并对账未确认项，禁止沿用旧瞬态失败根因 | L1 |
| P1 | [NET-06](../cards/NET-06-flow-delivery-async-202-reconcile-ledgers.md) | 🟡 剩余 5 项验收缺口已全部拆成独立子卡（NET-15~19），本卡待子卡全部归档后才能一并归档；**不再可单独领取**，去认领对应子卡 | L2 |
| P1 | [NET-15](../cards/NET-15-flow-status-must-respawn-a-lost-delivery-task-after-daemon-restart.md) | daemon 崩溃后 grant Active 但无运行任务，`status()` 需检测并重新拉起交付（断点续传，非从零）；NET-06 拆出 | L1 |
| P1 | [NET-16](../cards/NET-16-completed-status-repeated-fetch-must-not-retransmit-bytes.md) | completed 后重复 status/fetch 必须零重传字节的直接断言（防未来防御性代码悄悄二次拉取）；NET-06 拆出 | L1 |
| P1 | [NET-17](../cards/NET-17-late-boundary-race-between-materialize-and-cancel-suspend.md) | materialize 前后各发一次 cancel/suspend，两方向终态需确定性验证（先过 complete_flow_grant 者赢）；NET-06 拆出 | L1 |
| P1 | [NET-18](../cards/NET-18-legacy-phone-and-desktop-fallback-path-verification.md) | 旧手机（只用 fetch）+ 旧桌面（不认 flow.status）两条降级路径专门验证；NET-06 拆出 | L1 |
| P1 | [NET-19](../cards/NET-19-android-no-competing-offer-and-pause-does-not-observe.md) | offer 只调一次的断言 + 暂停路径零查询对端的断言；NET-06 拆出 | L1 |
| P1 | [NET-24](../cards/NET-24-flow-delivered-push-not-reaching-phone.md) | `flow.delivered` 推送在断链重连后真机场景里始终没送达手机，去重命中项要等满 30 秒兜底超时才被轮询捞回，而非瞬时完成；NET-23 拆出，根因未查 | L1 |
| P1 | [NET-07](../cards/NET-07-split-timeouts-by-call-kind-transitional.md) | 过渡止血：超时按 建连/控制/fetch 分档（NET-06 合入后评估回退）；与 NET-06 并行 | L1 |
| P1 | [NET-08](../cards/NET-08-audit-repo-for-sync-wait-weld-points.md) | 🟡 普查完成（2026-09-14，清单在卡内）：焊点全登记，衍生 NET-09/10/11、TEL-05 四张后续卡；本卡待后续卡闭环后归档，不再可领 | L2 |
| P1 | [NET-09](../cards/NET-09-data-plane-stall-watchdog-for-long-transfers.md) | 长数据面加字节停滞看门狗（downloadAsset 无界挂起 / APK 下载死因不可辨 / daemon upload 收流）；NET-08 产出 | L1 |
| P1 | [NET-11](../cards/NET-11-desktop-shell-ipc-read-timeout-fuse.md) | 桌面壳 IPC call 无读超时——daemon 挂死拖整壳冻死；固定保险丝+方法名报错；NET-08 产出 | L1 |
| P1 | [TEL-05](../cards/TEL-05-telemetry-http-timeout-and-queue-cap.md) | 遥测 reqwest 无超时：半死端点挂死 flush 循环、队列只进不出；NET-08 产出 | L1 |
| P2 | [NET-10](../cards/NET-10-pair-request-accept-then-poll-status.md) | 配对「提交≠等人」拆解（pair.request 硬等 120s、daemon 无限挂流）；复用 NET-06 status 形状，等其合入；NET-08 产出 | L2 |
| P1 | [AUDIT-02](../cards/AUDIT-02-activity-record-meaningful-projection.md) | 真实活动记录遗漏/误投影本轮照片与视频结果；必须按 canonical evidence 分列并准确汇总 | L2 |
| P1 | [UI-11](../cards/UI-11-android-system-bar-safe-area-contrast.md) | 白色页面顶部状态栏图标对比度不足，需实证统一安全区/system-bar 外观是否生效 | L1 |
| P2 | [NET-03](../cards/NET-03-idle-phone-floods-audit-with-connection-events.md) | 手机闲置时审计被连接事件刷屏——先取证定性真抖动 vs 误记 | L2 |
| P2 | [MOB-73](../cards/MOB-73-local-source-first-viewing.md) | 本机仍有原图时查看/保存/分享应读本地并验证 hash，远端仅作缺源回退 | L2 |
| P3 | [BUILD-01](../cards/BUILD-01-local-jdk25-breaks-release-lint.md) | 本机 JDK 25 让 Android release 构建挂 lint；CI 钉 17 不受影响 | L3 |
| P3 | [REL-04](../cards/REL-04-manifest-url-decided-before-mirror-succeeds.md) | manifest 地址在镜像成功前就写死 | L2 |
| P3 | 未开卡 | 活动流把机器原文直接显示给用户，需改文案 | L2 |
| P3 | [UI-07](../cards/UI-07-wrong-small-icon-has-no-lightning-mark.md) | 小 icon 用错版本，等验收人给修改指示 | L3 |
| P2 | [MOB-69](../cards/MOB-69-rebuild04-deleted-notification-senders.md) | REBUILD-04 批次删除带走哨兵/白名单/重传三条通知发送端（判定逻辑成死代码）；先定性再接线或显式下线 | L2 |
| P3 | [MOB-78](../cards/MOB-78-mob67-test-residue-in-production-library.md) | 生产照片库混入 MOB-67 测试残留假 JPEG（59 字节，显示白框），需清理并排查是否还有其他遗留测试文件 | L1 |
| P2 | [CI-03](../cards/CI-03-e2e-scenarios-test-frozen-legacy-flow.md) | `e2e.yml` 的 e2e/scenarios 两个 job 全在验证已冻结的 legacy 备份路径（`DaemonBackupTest`/`testclient backup`），新 Flow 核心零黑盒剧本覆盖；需先拍板标注/砍/换三选一 | L2 |
| P1 | [MOB-84](../cards/MOB-84-album-picker-renders-stale-overlay-and-taps-produce-no-visible-response.md) | 相册选择页设置开关残留叠加 + 点击相册卡片无可见响应（触屏事件已送达但界面装死），阻断发起备份；2026-09-16 NET-14 真机会话同轮发现 | L1 |
| P1 | [MOB-86](../cards/MOB-86-auto-backup-toggle-blocks-waiting-item-wakeup.md) | 关闭「后台备份」总开关后，等待中的排队项失去全部唤醒路径（切前后台/强退重开/重新开关约束均无效，唯一出路是重开总开关）；2026-09-16 真机回归发现 | L1 |
| P2 | [MOB-85](../cards/MOB-85-samsung-mars-policy-interrupts-foreground-service-protection.md) | 三星 MARs 资源策略在 NET-12 前台服务保护生效期间仍两次主动杀进程/降级服务；待排除与频繁卸装重装操作的相关性再定性 | L1 |

---

## 四、待你复现或拍板（agent 不许编码）

| 卡 | 一句话 | 当前等待 |
|---|---|---|
| [NET-01](../cards/NET-01-backup-begin-times-out-for-15s-then-backs-off.md) | 三星热点大视频已复现 `flow.fetch` 15 秒超时；2026-09-16 补齐判决实验（三星5G↔Mac家庭WiFi debug日志实证：确认落 relay + 反复打洞失败，但本次未复现15秒超时失败，传输走 relay 慢速完成）——"跨网络会落relay"已证实，"15秒超时是否仍是痛点"待专门复测原触发组合 | **等可持续的蜂窝热点 / relay 窗口后再改并跑大视频回归** |
| [MOB-52](../cards/MOB-52-oppo-bg-wake-fail-and-launch-crash.md) | OPPO Reno8 后台不触发上传 + 点开 App 闪退（L0）；09-12 v0.5.1 复测同族症状再现（后台 1 分钟零同步/进 App 卡崩溃/断开卡顿），崩溃栈仍未到手 | **等崩溃证据**，拿不到不编码 |
| [MOB-75](../cards/MOB-75-harmonyos-media-change-must-wake-flow-in-background.md) | HarmonyOS 4.2：已授权后台管理但相册变更等约 1 分钟不传，重开 App 才补捞 | **等同一设备的 MediaWatch/JobScheduler/ledger 证据，不能把系统归咎当根因** |
| [AUDIT-01](../cards/AUDIT-01-flow-audit-v2-durable-outbox.md) | `audit_event` v2 已被 AUDIT-04 canonical 四表直接替换 | **冻结**；不验旧 UI，不恢复旧模型 |
| [AUDIT-05](../cards/AUDIT-05-dogfood-week-audit-content-review.md) | 狗粮周后只读复核真实审计内容，验证既定预设的覆盖与字段关联 | **等狗粮周样本**；不阻塞 AUDIT-02 的首版 UI |
| [OBS-01](../cards/OBS-01-telemetry-privacy-consent-and-control.md) | 遥测默认 opt-out 且无 App 内隐私说明页/可见开关；OBS-02 字典与 TEL-01~04 已落地，当前仅自建自用，欠账真实但非合规危机 | **等默认值（opt-in / opt-out）与入口的产品拍板** |
| [UI-04d](../cards/UI-04d-reupload-notice-uses-failure-channel.md) | 重传通知挂在「失败」渠道——但发送函数已被 REBUILD-04 删除、生产零调用 | **等 MOB-69 拍板「重传要不要接回系统通知」，不是等用户** |

---

## 五、已完成但卡文件仍在 `cards/` 根目录（只剩归档动作）

> **已归档卡的账不在本文件。** 完成记录见 [PROGRESS.md](PROGRESS.md)（每卡一行 +
> 验收输出摘录）与 [ROADMAP.md](ROADMAP.md)（里程碑账本），卡文件在 `cards/done/`。
>
> 本节只剩一类残留：**卡已完成、但文件还留在 `cards/` 根目录**，所以
> `check-queue-sync.sh` 的「根卡必须在队列里」仍要求它们在此登记。把文件
> `git mv` 进 `cards/done/` 后，对应行从本节删掉即可，本节清空后整节删除。
>
> 归档出口由 `tools/check-queue-sync.sh` 3/3 段强制：活分区（一~四）不许出现
> 指向 `cards/done/` 的行，且分区集合固定。2026-09-16 清理前，原「已完成 /
> 已归档」分区有 45 行、14.1KB，是全文件最大的一块——而本文件头部自己写着
> 「只写跟"现在"有关的」。

| 卡 | 结果 | 已释放 |
|---|---|---|
| [MOB-55](../cards/MOB-55-cancel-current-round-tap-shows-no-feedback.md) | 卡内横幅：已被 [MOB-58](../cards/done/MOB-58-cancel-round-no-feedback-no-restore-entry.md) 收敛，不再独立开工 | — |
| [ARCH-02](../cards/ARCH-02-mobile-ledger-and-atomic-discovery.md) | D-01~D-04 账本/发现页原子提交完成 | ARCH-03 |
| [ARCH-03](../cards/ARCH-03-strict-consumer-pause-and-constraints.md) | C-01~C-05 严格消费者、Pause 与条件等待完成 | ARCH-04 |
| [ARCH-04](../cards/ARCH-04-completion-evidence-and-scope-revision.md) | E-01~E-04 完成凭据、范围竞争与 backfill 完成 | ARCH-05 |
| [REBUILD-00](../cards/REBUILD-00-legacy-fence-and-flow-boundary.md) | `backup/flow` 边界、legacy 标记与旧测试三类分类完成 | REBUILD-01 / REBUILD-02 |
| [REBUILD-01](../cards/REBUILD-01-android-iroh-blobs-provider-bridge.md) | Android native blobs provider / JNI / debug APK 接线完成 | REBUILD-03 |
| [REBUILD-02](../cards/REBUILD-02-desktop-native-fetch-and-completion-receipt.md) | Desktop native fetch/resume 与 durable receipt 完成 | REBUILD-03 |
| [REBUILD-03](../cards/REBUILD-03-production-flow-runner.md) | Flow runner、trigger bridge、native receipt 接线完成 | REBUILD-04 |
| [REL-03](../cards/REL-03-bump-script-silently-skips-desktop-crate-version.md) | 批次 A：版本脚本版本目标全断言 | 批次 CI |
| [BUILD-02](../cards/BUILD-02-toolchain-pin-must-bind-on-ci-too.md) | 批次 A：五个 workflow 从 TOML 派生 Rust 工具链 | 批次 CI |

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
| [MOB-80](../cards/backlog/MOB-80-video-preview-should-default-muted.md) | 暂缓，等换播放器 | 2026-09-15 用户拍板：移动端视频预览默认静音 + 音量控制入口，等下次评估/更换视频播放器组件时一并设计；现有 Media3 PlayerView 默认控件无音量滑块/静音按钮，不单独定制 |
| [MOB-81](../cards/backlog/MOB-81-legacy-watch-job-detached-from-flow-truth.md) | 待用户回头确认方向 | 2026-09-15：UI-12 真机验证发现 `SystemStoppedWatcher` 判据查的是 legacy JobScheduler（`MediaWatchJob`），非当前 Flow 主链路，真机 force-stop 后系统自动重排该 job 导致无法稳定复现该状态；判据本身有 16 个单测覆盖非回归风险，只是信号源脱节；影响面小（不影响真实备份，只影响这条提示是否准确弹出），不紧急 |

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
