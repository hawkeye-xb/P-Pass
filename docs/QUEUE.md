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
> 最后核对：**2026-09-01**（ARCH-05 已完成；ARCH-01 首批 P0 实施卡全部完成）

---

## 〇、当前阶段背景（process，别重新摸索）

- **阶段**：真机回归驱动的修 bug 循环。代码侧健康（本机全绿），**卡住的
  是真机验收**，不是代码没写。
- **最新可测版本**：`v0.4.0-test.9`（含 MOB-38 + UX-13 + MOB-40 + UX-14 + CI-04①）。
- **本机全绿基线**：`just ci` all green · nextest 320 passed / 1 skipped ·
  Android 46 类 / 347 tests / 0 failures · 桌面 `pnpm test 24` +
  `src-tauri cargo test --lib 15`。
- **环境事实**：验收人照片库 `~/Pictures/P-Pass 家庭照片库`（**真实数据，
  一个字节都不许碰**）；测试机三星 SM-S9210，**不许做 adb 写操作**；
  `gh` 未登录、仓库私有 → 看不到 Actions 结论，push 后要验收人自己扫 CI。
- **范围红线**：文件备份 / 文件同步整个不在范围内，**只做图片**。

---

## 一、进行中（已认领，禁止重复接）

| 卡 | 当前节点 | 下一步 | 协同分支 |
|---|---|---|---|






认领、暂停、交接必须先更新本节对应卡的横幅与下一步并 push；未上云的状态不算认领。其他 agent fetch 后只从下一节接卡。

---

## 二、刚完成（推动下游，非可接）

| 卡 | 结果 | 已释放 |
|---|---|---|
| [ARCH-02](../cards/ARCH-02-mobile-ledger-and-atomic-discovery.md) | D-01~D-04 账本/发现页原子提交完成 | ARCH-03 |
| [ARCH-03](../cards/ARCH-03-strict-consumer-pause-and-constraints.md) | C-01~C-05 严格消费者、Pause 与条件等待完成 | ARCH-04 |
| [ARCH-04](../cards/ARCH-04-completion-evidence-and-scope-revision.md) | E-01~E-04 完成凭据、范围竞争与 backfill 完成 | ARCH-05 |
| [ARCH-05](../cards/done/ARCH-05-cancellation-round.md) | X-01~X-05 取消本轮、恢复与丢弃完成 | ARCH-01 后续实施拆卡 |
| [ARCH-06](../cards/done/ARCH-06-pairing-epoch-isolation.md) | P-01/P-02 换 Desktop 的 epoch 隔离完成 | ARCH-01 P1 对账拆卡 |
| [ARCH-07](../cards/done/ARCH-07-remote-reconciliation-facts.md) | R-01/R-02 对账事实与恢复裁决完成 | ARCH-08 |
| [ARCH-08](../cards/done/ARCH-08-remote-presence-probe.md) | side-effect-free Desktop presence page 完成 | P1 分页选择 / 源探针 / 账本裁决接线卡 |
| [ARCH-09](../cards/done/ARCH-09-reconciliation-page-coordinator.md) | P1 账本分页、source probe 与 R-01/R-02 裁决协调完成 | 低频调度 / UI 卡 |
| [REBUILD-00](../cards/REBUILD-00-legacy-fence-and-flow-boundary.md) | `backup/flow` 边界、legacy 标记与旧测试三类分类完成 | REBUILD-01 / REBUILD-02 |
| [REL-03](../cards/REL-03-bump-script-silently-skips-desktop-crate-version.md) | 批次 A：版本脚本版本目标全断言 | 批次 CI |
| [BUILD-02](../cards/BUILD-02-toolchain-pin-must-bind-on-ci-too.md) | 批次 A：五个 workflow 从 TOML 派生 Rust 工具链 | 批次 CI |

---

## 三、待 ARCH-01 重拆（旧实现卡冻结，agent 不许按旧卡实施）

| 卡 | 冻结原因 | 正确下一步 |
|---|---|---|
| [MOB-39](../cards/MOB-39-triggers-are-data-pipeline-is-one.md) | 旧 `TriggerSpec` / WorkManager 管线形状已被 ARCH-01 取代 | 从 ARCH-01 case matrix 拆新实施卡 |
| [MOB-42](../cards/MOB-42-pause-leaves-two-channels-running.md) | 旧 WorkManager 通道枚举不再是 Pause 的架构边界 | 从 ARCH-01 Pause / consumer gate case 拆新实施卡 |
| [MOB-48](../cards/MOB-48-pause-resume-must-preserve-original-trigger-spec.md) | 依赖旧 `TriggerSpec` / enqueue facade 形状 | 从 ARCH-01 Continue / 条件等待 case 拆新实施卡 |

> 旧测试不许阻塞新架构；保留的产品不变量必须从 ARCH-01 case matrix 重新写成
> 失败用例。新卡未拆前，本节卡禁止认领和实施。

---

## 四、ARCH-01 后续实施拆卡（按已收口边界开卡）

| 卡 | 覆盖 case | 当前等待 |
|---|---|---|
| [ARCH-01](../cards/ARCH-01-backup-core-flow-queue-design.md) | 后续拆卡边界 | ARCH-02~09 仅为未接生产骨架；REBUILD-00~04 执行生产切换 |

> self-review 已核对 case 覆盖、依赖顺序、范围与反证；ARCH-01 已定的产品语义不重开。
> ARCH-02、ARCH-03、ARCH-04、ARCH-05、ARCH-06 已完成；后续只可从 ARCH-01 的既定拆卡边界继续。

### 重建主线（唯一开发优先级）

| 阶段 | 卡 | 依赖 | 交付 |
|---|---|---|---|
| R0 | [REBUILD-00](../cards/REBUILD-00-legacy-fence-and-flow-boundary.md) | — | ✅ 旧线冻结、新 Flow 边界 |
| R1a | [REBUILD-01](../cards/REBUILD-01-android-iroh-blobs-provider-bridge.md) | R0 | Android blobs provider bridge |
| R1b | [REBUILD-02](../cards/REBUILD-02-desktop-native-fetch-and-completion-receipt.md) | R0 | Desktop fetch + completion receipt |
| R2 | [REBUILD-03](../cards/REBUILD-03-production-flow-runner.md) | R1a、R1b | 新生产 Flow runner |
| R3 | [REBUILD-04](../cards/REBUILD-04-worker-cutover-debug-apk.md) | R2 | debug APK + 三星首验 |

---

## 五、可接队列（无阻塞，可以直接分给任何 agent）

| 优先级 | 卡 | 一句话 | 级别 |
|---|---|---|---|



| P2 | [DOG-03](../cards/DOG-03-battery-whitelist-must-be-on-the-onboarding-path.md) | 三星退到后台 20 秒就冻进程、看门 job 直接丢——把「加电池白名单」提成 onboarding 必经一步 | L1 |
| P2 | [NET-01](../cards/NET-01-backup-begin-times-out-for-15s-then-backs-off.md) | 根因链已闭合（relay 15s 超时→backup.begin 从未送达），卡内建议提级 L0 等验收人拍板；2026-08-27 鸿蒙三次静默复现与该链条吻合，下一步等验收人换 OPPO Reno8 真机 logcat 交叉验证 | L2 |
| P2 | [MOB-41](../cards/MOB-41-reupload-notice-fires-before-the-scope-filter.md) | 重传提示发在范围过滤之前——删掉范围外的照片会弹「正在重传」然后什么也不传 | L2 |
| P2 | [MOB-46](../cards/MOB-46-album-selection-count-inflated.md) | 相册计数虚高：选 3 显 7、选 4 显 8（恒 +4）——计数说谎，伤范围信任 | L1 |
| P2 | [MOB-44](../cards/MOB-44-harmonyos-no-background-for-restore.md) | 鸿蒙上恢复备份退后台就不跑（需鸿蒙真机取证窗口，与 DOG-03 同族） | L1 |
| P2 | [NET-03](../cards/NET-03-idle-phone-floods-audit-with-connection-events.md) | 手机闲置时审计被连接事件刷屏——先取证定性真抖动 vs 误记（PRES-01 在读 device.connected，口径不能乱动） | L2 |
| P2 | [MOB-45](../cards/MOB-45-android-swipe-back-gesture.md) | Android 侧滑返回手势 + 查看页手势分层（与 MOB-26 交集已互相标注） | L2 |
| P2 | [MOB-47](../cards/MOB-47-video-preview-in-viewer.md) | 视频资产查看器不可预览——桌面 `<img>` 破图（原图 base64 错标 image/jpeg）、Android 仅 VideoView MVP；桌面 `<video>` 分流先行，Android 换 Media3 ExoPlayer（2026-08-29 验收人派单） | L2 |

| P3 | [SYNC-05](../cards/SYNC-05-asset-meta-src-device.md) | AssetMeta 补来源设备字段，消灭客户端影子状态 | L1 |

| P3 | [CI-03](../cards/CI-03-src-tauri-workspace-has-no-fmt-gate.md) | 桌面壳 workspace 没有 fmt/clippy 门禁（⚠️ 要动 workflows，先确认由谁改） | L0 |
| P3 | [BUILD-01](../cards/BUILD-01-local-jdk25-breaks-release-lint.md) | 本机 JDK 25 让 Android release 构建挂 lint（CI 钉 17 不受影响） | L3 |
| P3 | [UI-04](../cards/UI-04-notice-presentation-three-defects.md) | 提示呈现三连：只在总览 / 改名用占布局的条 / 多条堆叠 | L2 |
| P3 | [LINT-01](../cards/LINT-01-android-lint-not-in-ci.md) | Android lint 不在 CI 里跑，红了没人看见 | L3 |
| P3 | [CI-02](../cards/CI-02-e2e-compiles-release-binaries-twice.md) | e2e nightly 两个 job 各自编译一遍 release 二进制（~300 Linux 分钟/月白烧） | L3 |

| P3 | [REL-04](../cards/REL-04-manifest-url-decided-before-mirror-succeeds.md) | manifest 地址在镜像成功前就写死（R2 镜像已撤，本卡是重开镜像的前置） | L2 |
| P3 | 未开卡 | 活动流把机器原文（`asset.replaced_in_place` 等）直接显示给用户，需改文案 | L2 |
| P3 | [MOB-26](../cards/MOB-26-photo-viewer-needs-real-library.md) | 照片查看器换成熟开源库（Telephoto/ZoomImage 等）+ 读 EXIF——2026-08-27 验收人重提解冻，从 backlog 移回 | L2 |
| P3 | [UI-07](../cards/UI-07-wrong-small-icon-has-no-lightning-mark.md) | 小 icon 用错版本——当前引用了不带闪电标识的 icon（阻塞：等验收人给修改指示） | L3 |
| P3 | [UI-08](../cards/UI-08-album-picker-long-name-wraps-and-thumb-blurry.md) | 选相册页长名称换行撑乱布局 + 缩略图模糊 | L3 |
| P3 | [I18N-02](../cards/I18N-02-main-kotlin-hardcoded-chinese.md) | 主 Android Kotlin 的无关既有用户可见中文硬编码清债 | L1 |
| P4（顺手做，不派活） | [CI-04](../cards/CI-04-release-waits-for-the-slowest-platform.md) | 代码①②都已合并（先建草稿、各平台自己上传），不存在权限拍板；剩的是下次你自己发版时顺手拿一次真实 workflow_dispatch/release 验证一下缓存和拆分是否真生效——2026-08-27 用户定为最低优先级 | L1 |

**派活提示**：P1/P2 里的 L0/L1 卡属于「成本在做」，按 AGENTS.md 的派活姿势，
把根因/文件/行号内联进指令即可，不必要求 agent 先通读协议文档。

---

## 六、待你真机验收（代码已合并，就差你动手）

| 卡 | 一句话 | 级别 |
|---|---|---|
| [UX-14](../cards/UX-14-a-failed-retry-is-rendered-as-paused.md) | 暂停 → 继续 → 传输中途关掉 desktop 的 daemon 制造一次连接中断 → 界面**不许**又显示「继续」（应该说它的真实状态：还有 N 张待备份 / 出错了） | L1 |
| [MOB-40](../cards/MOB-40-backup-runs-before-the-user-picks-albums.md) | **卸载重装 → 配对 → 只选那个 11 张的相册 → 全程只传 11 张**；配对到选完相册之间一张都不许传（这一条不过，别的都不用测） | L0 |
| [DESK-10](../cards/DESK-10-export-logs-omits-the-only-logs-that-matter.md) | **复验**（8/26 打回的脱敏漏已补）：①daemon 正常时导出日志 → 9 个文件都在；②daemon 挂着时导出 → 仍出 zip 含 `.err`/`.log`；③grep 整个 zip 不许出现用户名；④`audit.json`/`diag_events.json` 里路径应是 `originals/<8位前缀>…<masked>/…`，看不到完整 hex | L1 |
| [MOB-38](../cards/MOB-38-foreground-catchup-never-fires-on-resume.md) | 从 App 切到相机拍一张再切回来，照片自动传上去 | L0 |
| [UX-13](../cards/UX-13-no-resume-affordance-after-pause.md) | 备份中点「暂停」→ 按钮留在原地变「继续」→ 点它 → 传输接着跑；暂停后杀 App 重开「继续」还在；备份正常跑完「继续」自己消失 | L1 |
| [WATCH-07](../cards/WATCH-07-self-inflicted-duplicate-audit-noise.md) | 备份后活动流不再被「重复」审计刷屏 | L2 |
| [MOB-19](../cards/MOB-19-manual-backup-same-bad-record-crash.md) | 手动「再试一次」与自动备份是同一条管线 | L2 |
| [MOB-09](../cards/MOB-09-one-bad-media-record-kills-batch.md) | 一条坏相册记录不再炸掉整批备份（欠一半：好坏同批未验） | L2 |
| [MOB-13](../cards/MOB-13-triplet-k-never-reaches-zero.md) | 「待备份 K」能归零（有前置，见卡） | L2 |
| [BLOB-01](../cards/BLOB-01-ingest-leaves-a-duplicate-in-the-blob-store.md) | 备份占盘不再翻倍（实测 2.05x → 1.00x） | L2 |
| [E2E-02](../cards/E2E-02-daemon-hello-test-asserts-dead-contract.md) | e2e 门禁已解红，下次打 tag 复核 | L1 |
| [I18N-01](../cards/I18N-01-unnamed-album-fallback-is-hardcoded-chinese.md) | 英文系统下空相册名显示 Unnamed | L3 |
| [DESK-09](../cards/DESK-09-wizard-swallows-daemon-startup-error.md) | 旧 daemon 打开新版库时向导显示真实 stderr 与升级提示 | L1 |

**已有真机证据的**（2026-08-21 审计，仅供复核）：MOB-30、WATCH-02。

**2026-08-27 验收人已批量关闭**（不要求逐条真机复核）：MOB-28、MOB-31、
MOB-33、MOB-35 → 已移入 `done/`；MOB-43 → 判定不需要实现，已移入 `done/`。

**2026-08-27 验收人第二批真机验收通过，已归档 `done/`**：MOB-32、MOB-37、
MOB-29、MOB-34、MOB-36、WATCH-03、WATCH-04、DESK-08、UI-03。

**验收建议**：15 分钟一批过，别攒。

---

## 七、待你拍板（不定就动不了）

**当前为空。**2026-08-27 清空：Apple 签名/公证已确认早就补齐、CI 一直在
真跑,不是待拍板；「两个本机问题」指向的 `local-state.md` 已不
存在、内容丢失，不再挂账——有新的本机问题请直接口述，我会重新建这个文件；
MOB-43 已判定不需要实现,不再是拍板项。

---

## 八、backlog（明确不做或暂缓，agent 不许碰）

| 卡 | 状态 | 备注 |
|---|---|---|
| [MOB-07](../cards/MOB-07-partial-access-global-indicator.md) | 暂不做 | 2026-08-14 拍板 |
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
