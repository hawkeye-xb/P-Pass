# P-Pass 待办队列（验收人仪表盘）

> **本文件是项目状态的对齐入口与统筹台。**
> 排优先级 = 挪动三区的行；派活 = 把卡号交给执行者。
> 执行卡的 session 不读本文件（只读 `AGENTS.md` + 指定卡）；
> 状态对齐的 session（问进度/下一张做什么/该验收什么）从本文件 +
> `PROGRESS.md` **顶部表格**开始（该文件开头自己写着"按完成时间倒序"——
> 最新一条在第一行；文件*末尾*是最旧的编年段落，2026-08-26 就停了）。
>
> 每行只写统筹所需的一句：状态 / 卡在等什么。执行所需的细节（根因、
> 文件行号、证据）在卡里，不在本文件。每一条只能从卡面"读出"。
> 本机路径/设备状态在 `local-state.md`（不进 git）。
> 旧版全文见分支 `archive/rules-v1-2026-09-16`；完成账本在
> `PROGRESS.md` / `ROADMAP.md`。
>
> 最近一轮：2026-09-16 三星真机跨网络回归（NET-01 补 relay 判决证据；
> MOB-71/76 各过部分核心场景；新发现 MOB-85/86 入可接队列）。

---

## 〇、当前阶段背景（process，别重新摸索）

- **阶段**：真机回归驱动的修 bug 循环。代码侧健康（本机全绿），**卡住的
  是真机验收**，不是代码没写。
- **最新可测版本**：`v0.5.1-test.1`（2026-09-12）。改版本号后务必同步这里。
- **本机全绿基线**：`just ci` all green · nextest 345 passed / 1 skipped ·
  Android 46 类 / 347 tests / 0 failures · 桌面 `pnpm test 58`
  + `src-tauri cargo test --lib 18`（2026-09-09 核实）。
- **环境事实**：验收人照片库 `~/Pictures/P-Pass 家庭照片库`（**原始照片
  文件不许碰**；派生数据可动）；测试机三星 SM-S9210，**不许做 adb 写
  操作**。`gh` 未登录 → push 后要验收人自己扫 CI。
- **范围红线**：文件备份 / 文件同步整个不在范围内，**只做图片**。

---

## 一、进行中

| 卡 | 一句话 | 级别 |
|---|---|---|

> 空表是常态：只在当前会话里真有人盯着改时才填；会话结束必须挪回准确分区。

---

## 二、待共享回归（代码已合并，就差你动手）

| 卡 | 一句话 | 级别 |
|---|---|---|
| [NET-14](../cards/NET-14-desktop-completion-must-push-not-poll-local-transfer-is-ground-truth.md) | 同 WiFi 冒烟已过；待三星热点大视频跨 relay、idle 兜底、NET-12 长期存活三项真机硬门 | L2 |
| [NET-12](../cards/NET-12-flow-transfer-lacks-foreground-service-protection.md) | 前台服务保护已接回，三星 adj 锁定 200；待长期真机观察 | L2 |
| [MOB-68](../cards/MOB-68-optional-permissions-map-to-backup-settings.md) | 待 HarmonyOS 4.2 真机验证 | L2 |
| [UI-04a](../cards/UI-04a-interruption-notice-only-visible-on-home.md) | 真机复核"状态不对"，待你说明具体点 | L2 |
| [UI-09](../cards/UI-09-aggregate-status-must-read-flow-ledger.md) | 待验收传完后 AllSafe 与「待备份 K」归零流转 | L2 |
| [MOB-62](../cards/MOB-62-unpair-must-reset-flow-runtime-and-wakes.md) | 待完整断开重扫回归 | L2 |
| [MOB-72](../cards/MOB-72-scope-selection-must-wake-flow-without-relaunch.md) | 待三星取消轮后新相册不重启传输回归 | L2 |
| [MOB-76](../cards/MOB-76-wifi-only-constraint-must-block-cellular-transfer.md) | 限制开启+纯蜂窝已验证；待补"连 Wi-Fi 自动续传" | L1 |
| [MOB-71](../cards/MOB-71-paused-flow-must-not-show-wifi-wait-when-wifi-only-off.md) | 核心场景已过；待补"重开限制恢复等待提示" | L1 |
| [MOB-64](../cards/MOB-64-revoked-device-gets-no-feedback-until-next-attempt.md) | 待三星重配对后撤销设备验证；OPPO 冷启动零提示待取证 | L2 |
| [NET-04](../cards/NET-04-connection-path-tracking-for-transfer-and-billing.md) | 测试文件全 CONFIRMED；待回归 Pause / Cancel / 失败 Retry | L2 |
| [NET-05](../cards/NET-05-flow-data-path-status-follows-transfer-lifecycle.md) | 待慢速传输及 Pause/Cancel/失败真机回归 | L2 |
| [MOB-26](../cards/MOB-26-photo-viewer-needs-real-library.md) | 页序、Telephoto 缩放/下拉关闭、系统返回层级 | L2 |
| [DESK-10](../cards/DESK-10-export-logs-omits-the-only-logs-that-matter.md) | 正常包已过；不可达分支需 agent 隔离故障环境实证 | L1 |
| [WATCH-07](../cards/WATCH-07-self-inflicted-duplicate-audit-noise.md) | 备份后活动流不再被「重复」审计刷屏 | L2 |
| [E2E-02](../cards/E2E-02-daemon-hello-test-asserts-dead-contract.md) | e2e 门禁已解红，下次打 tag 复核 | L1 |
| [I18N-01](../cards/I18N-01-unnamed-album-fallback-is-hardcoded-chinese.md) | 空相册名兜底已本地化，英文系统真机过一眼 | L3 |
| [DESK-09](../cards/DESK-09-wizard-swallows-daemon-startup-error.md) | 旧 daemon 开新库时向导显示真实 stderr 与升级提示 | L1 |
| [MOB-60](../cards/MOB-60-cancel-round-leaves-stale-pause.md) | 取消当前轮后落 Idle，不显示暂停/继续/取消 | L1 |
| [DESK-13](../cards/DESK-13-ingest-blocks-tokio-runtime-freezes-desktop-ui.md) | 大文件传输时桌面 UI 不应冻结 | L0 |
| [MOB-57](../cards/MOB-57-pause-cancel-buttons-lack-pending-state.md) | 暂停/取消连点只接受一次并有处理中反馈 | L1 |
| [UI-10](../cards/UI-10-flow-runtime-blindness-and-legacy-ui-tails.md) | epoch 自愈/重传提示/归属过滤/失联提示组合回归 | L3 |
| [DESK-11](../cards/DESK-11-flow-ingest-not-live-in-library-view.md) | Flow 摄入后桌面库实时出现照片 | L1 |
| [MOB-56](../cards/MOB-56-unsynchronized-delivery-callbacks-race-strict-head.md) | 并发回调不触发同一队头双发 | L0 |
| [MOB-53](../cards/MOB-53-legacy-confirmed-items-missing-completedat.md) | 旧账本补 completedAt，首页不再永久显示从未成功 | L1 |
| [UI-12](../cards/UI-12-notice-presentation-not-material-banner.md) | 全局 NoticeHost + 安全区适配已验证；待你鸿蒙 OPPO 二次核对 | L2 |
| [UI-13](../cards/UI-13-android-hand-rolled-widgets-not-material3.md) | M3 组件替换完成，待你复核视觉 | L2 |

**已有真机证据待复核**：MOB-30、WATCH-02（2026-08-21 审计）。

**验收建议**：15 分钟一批过，别攒。

---

## 三、可接队列（无阻塞，可以直接分给任何 agent）

| 优先级 | 卡 | 一句话 | 级别 |
|---|---|---|---|
| P0 | [MOB-54](../cards/MOB-54-transient-failure-does-not-auto-retry.md) | 三星 32 张相册停摆取证：重放 receipt 与 discovery wake 交错对账，禁止沿用旧根因 | L1 |
| P1 | [NET-06](../cards/NET-06-flow-delivery-async-202-reconcile-ledgers.md) | 🟡 已拆 NET-15~19 子卡；本卡不再可领，去认领子卡 | L2 |
| P1 | [NET-15](../cards/NET-15-flow-status-must-respawn-a-lost-delivery-task-after-daemon-restart.md) | daemon 重启后 status() 检测并重新拉起丢失的交付（断点续传） | L1 |
| P1 | [NET-16](../cards/NET-16-completed-status-repeated-fetch-must-not-retransmit-bytes.md) | completed 后重复 status/fetch 零重传字节断言 | L1 |
| P1 | [NET-17](../cards/NET-17-late-boundary-race-between-materialize-and-cancel-suspend.md) | materialize 前后 cancel/suspend 双向终态确定性验证 | L1 |
| P1 | [NET-18](../cards/NET-18-legacy-phone-and-desktop-fallback-path-verification.md) | 旧手机（只 fetch）+ 旧桌面（不认 flow.status）降级路径验证 | L1 |
| P1 | [NET-19](../cards/NET-19-android-no-competing-offer-and-pause-does-not-observe.md) | offer 只调一次 + 暂停路径零查询对端断言 | L1 |
| P1 | [NET-24](../cards/NET-24-flow-delivered-push-not-reaching-phone.md) | flow.delivered 推送断链重连后送不达手机，根因未查（NET-23 拆出） | L1 |
| P1 | [NET-07](../cards/NET-07-split-timeouts-by-call-kind-transitional.md) | 过渡止血：超时按建连/控制/fetch 分档 | L1 |
| P1 | [NET-08](../cards/NET-08-audit-repo-for-sync-wait-weld-points.md) | 🟡 普查完成，衍生 NET-09/10/11、TEL-05；待后续卡闭环，不再可领 | L2 |
| P1 | [NET-09](../cards/NET-09-data-plane-stall-watchdog-for-long-transfers.md) | 长数据面字节停滞看门狗 | L1 |
| P1 | [NET-11](../cards/NET-11-desktop-shell-ipc-read-timeout-fuse.md) | 桌面壳 IPC call 读超时保险丝 | L1 |
| P1 | [TEL-05](../cards/TEL-05-telemetry-http-timeout-and-queue-cap.md) | 遥测 reqwest 超时 + 队列上限 | L1 |
| P2 | [NET-10](../cards/NET-10-pair-request-accept-then-poll-status.md) | 配对「提交≠等人」拆解；等 NET-06 合入 | L2 |
| P1 | [AUDIT-02](../cards/AUDIT-02-activity-record-meaningful-projection.md) | 活动记录按 canonical evidence 分列准确汇总 | L2 |
| P1 | [UI-11](../cards/UI-11-android-system-bar-safe-area-contrast.md) | 状态栏图标对比度：实证安全区/system-bar 外观生效 | L1 |
| P2 | [NET-03](../cards/NET-03-idle-phone-floods-audit-with-connection-events.md) | 闲置审计刷屏：先取证定性真抖动 vs 误记 | L2 |
| P2 | [MOB-73](../cards/MOB-73-local-source-first-viewing.md) | 本机有原图时读本地并验 hash，远端仅回退 | L2 |
| P3 | [BUILD-01](../cards/BUILD-01-local-jdk25-breaks-release-lint.md) | 本机 JDK 25 挂 release lint；CI 钉 17 不受影响 | L3 |
| P3 | [REL-04](../cards/REL-04-manifest-url-decided-before-mirror-succeeds.md) | manifest 地址在镜像成功前写死 | L2 |
| P3 | 未开卡 | 活动流把机器原文直接显示给用户，需改文案 | L2 |
| P3 | [UI-07](../cards/UI-07-wrong-small-icon-has-no-lightning-mark.md) | 小 icon 用错版本，等验收人指示 | L3 |
| P2 | [MOB-69](../cards/MOB-69-rebuild04-deleted-notification-senders.md) | REBUILD-04 删走三条通知发送端；先定性再接线或显式下线 | L2 |
| P3 | [MOB-78](../cards/MOB-78-mob67-test-residue-in-production-library.md) | 生产库混入测试残留假 JPEG，清理 + 排查 | L1 |
| P2 | [CI-03](../cards/CI-03-e2e-scenarios-test-frozen-legacy-flow.md) | e2e 两 job 全在验证冻结 legacy 路径；待拍板标注/砍/换 | L2 |
| P1 | [MOB-84](../cards/MOB-84-album-picker-renders-stale-overlay-and-taps-produce-no-visible-response.md) | 相册选择页残留叠加 + 点击无响应，阻断发起备份 | L1 |
| P1 | [MOB-86](../cards/MOB-86-auto-backup-toggle-blocks-waiting-item-wakeup.md) | 关总开关后排队项失去全部唤醒路径 | L1 |
| P2 | [MOB-85](../cards/MOB-85-samsung-mars-policy-interrupts-foreground-service-protection.md) | 三星 MARs 在前台服务保护期间仍杀进程；待排除卸装相关性再定性 | L1 |

---

## 四、待你复现或拍板（agent 不许编码）

| 卡 | 一句话 | 当前等待 |
|---|---|---|
| [NET-01](../cards/NET-01-backup-begin-times-out-for-15s-then-backs-off.md) | 跨网络落 relay 已证实；"15s 超时是否仍是痛点"待复测原触发组合 | 等可持续蜂窝热点 / relay 窗口 |
| [MOB-52](../cards/MOB-52-oppo-bg-wake-fail-and-launch-crash.md) | OPPO 后台不触发上传 + 点开闪退，崩溃栈未到手 | 等崩溃证据，拿不到不编码 |
| [MOB-75](../cards/MOB-75-harmonyos-media-change-must-wake-flow-in-background.md) | HarmonyOS 相册变更约 1 分钟不传，重开 App 才补捞 | 等同设备 MediaWatch/JobScheduler/ledger 证据 |
| [AUDIT-01](../cards/AUDIT-01-flow-audit-v2-durable-outbox.md) | 已被 AUDIT-04 canonical 四表替换 | 冻结 |
| [AUDIT-05](../cards/AUDIT-05-dogfood-week-audit-content-review.md) | 狗粮周后只读复核真实审计内容 | 等狗粮周样本 |
| [OBS-01](../cards/OBS-01-telemetry-privacy-consent-and-control.md) | 遥测默认 opt-out 且无 App 内隐私说明页/开关 | 等产品拍板（默认值与入口） |
| [UI-04d](../cards/UI-04d-reupload-notice-uses-failure-channel.md) | 重传通知发送函数已被删、生产零调用 | 等 MOB-69 拍板 |

---

## 五、待归档动作（卡已完成，文件待 `git mv` 进 `cards/done/`）

> 卡已完成但文件还留在 `cards/` 根目录的在此登记（门禁要求根卡必须
> 在队列里）；`git mv` 进 `done/` 后删行即可，本节清空后整节删除。
> 完成账本在 [PROGRESS.md](PROGRESS.md) / [ROADMAP.md](ROADMAP.md)。

| 卡 | 结果 | 已释放 |
|---|---|---|
| [ARCH-01](../cards/ARCH-01-backup-core-flow-queue-design.md) | 拆卡主线全部完成（ARCH-02~06、REBUILD-00~06 ✅），设计卡待归档 | — |
| [MOB-55](../cards/MOB-55-cancel-current-round-tap-shows-no-feedback.md) | 已被 [MOB-58](../cards/done/MOB-58-cancel-round-no-feedback-no-restore-entry.md) 收敛 | — |
| [ARCH-02](../cards/ARCH-02-mobile-ledger-and-atomic-discovery.md) | 账本/发现页原子提交完成 | ARCH-03 |
| [ARCH-03](../cards/ARCH-03-strict-consumer-pause-and-constraints.md) | 严格消费者、Pause 与条件等待完成 | ARCH-04 |
| [ARCH-04](../cards/ARCH-04-completion-evidence-and-scope-revision.md) | 完成凭据、范围竞争与 backfill 完成 | ARCH-05 |
| [REBUILD-00](../cards/REBUILD-00-legacy-fence-and-flow-boundary.md) | 旧线冻结、新 Flow 边界完成 | REBUILD-01 / REBUILD-02 |
| [REBUILD-01](../cards/REBUILD-01-android-iroh-blobs-provider-bridge.md) | Android blobs provider bridge 完成 | REBUILD-03 |
| [REBUILD-02](../cards/REBUILD-02-desktop-native-fetch-and-completion-receipt.md) | Desktop fetch/resume 与 durable receipt 完成 | REBUILD-03 |
| [REBUILD-03](../cards/REBUILD-03-production-flow-runner.md) | 新生产 Flow runner 完成 | REBUILD-04 |
| [REL-03](../cards/REL-03-bump-script-silently-skips-desktop-crate-version.md) | 版本脚本版本目标全断言 | — |
| [BUILD-02](../cards/BUILD-02-toolchain-pin-must-bind-on-ci-too.md) | 五个 workflow 从 TOML 派生 Rust 工具链 | — |

---

## 六、backlog（明确不做或暂缓，agent 不许碰）

| 卡 | 状态 | 备注 |
|---|---|---|
| [MOB-07](../cards/MOB-07-partial-access-global-indicator.md) | 暂不做 | 2026-08-14 拍板 |
| [DOG-03](../cards/backlog/DOG-03-battery-whitelist-must-be-on-the-onboarding-path.md) | 明确不做 | 2026-09-07 拍板：电池白名单不进 onboarding；接受该场景后台备份不工作 |
| WATCH-05 | 要做，实施前重开讨论 | inode 身份缓存 |
| WATCH-06 | 明确不做 | 不要软链物化视图 |
| MOB-25 | 暂不做 | 查看页尺寸显示 0×0，2026-08-19 拍板 |
| MOB-18 | superseded | 已被 MOB-28 取代，禁止按本卡实施 |
| DESK-11 | 待确认 | 若确认露完整 hex 则升级为 DESK-10 脱敏漏 |
| UI-05 / UI-06 | 用户暂时接受 | 展示细节，低优 |
| [DESK-15](../cards/done/DESK-15-desktop-design-system-convergence.md) | 暂缓 | Button 图标变体等真实调用场景出现再补 |
| [MOB-80](../cards/backlog/MOB-80-video-preview-should-default-muted.md) | 暂缓，等换播放器 | 视频预览默认静音，随播放器评估一并设计 |
| [MOB-81](../cards/backlog/MOB-81-legacy-watch-job-detached-from-flow-truth.md) | 待确认方向 | SystemStoppedWatcher 判据信号源脱节，影响面小不紧急 |

---

## 七、相关文档指路

- agent 规范（唯一必读）：[`AGENTS.md`](../AGENTS.md)
- 验收协议细则：[`AGENT_PROTOCOL.md`](AGENT_PROTOCOL.md)
- 发版/签名/部署：[`RELEASING.md`](RELEASING.md)
- 完成账本：[`PROGRESS.md`](PROGRESS.md) · [`ROADMAP.md`](ROADMAP.md)
- 历史教训归档：[`lessons/`](lessons/) 与分支 `archive/rules-v1-2026-09-16`
