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
> 最后核对：**2026-08-27**（commit `c843dd6`）

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

## 一、可接队列（无阻塞，可以直接分给任何 agent）

| 优先级 | 卡 | 一句话 | 级别 |
|---|---|---|---|
| P0 | [NET-02](../cards/NET-02-relay-handshake-failures-write-73mb-of-stderr.md) | relay 握手失败时 stderr 无节流狂写（实测 7 分钟 92211 行/73MB），持续发生会把磁盘写满；跟备份传输抢 IO、也把真正有用的日志埋掉。2026-08-27 用户定为最高优先级 | L2 |
| P2 | [MOB-39](../cards/MOB-39-triggers-are-data-pipeline-is-one.md) | 触发层抽象：触发是数据、管线只有一条——治「每次新增触发都漏接一处」这个病根（MOB-33/34/35/38/42 反复复发的同一个病） | L1 |
| P2 | [DOG-03](../cards/DOG-03-battery-whitelist-must-be-on-the-onboarding-path.md) | 三星退到后台 20 秒就冻进程、看门 job 直接丢——把「加电池白名单」提成 onboarding 必经一步 | L1 |
| P2 | [NET-01](../cards/NET-01-backup-begin-times-out-for-15s-then-backs-off.md) | 半小时内三次传输层失败，`backup.begin` 卡满 15 秒才超时；**还在定性阶段**，等下次复现时的 daemon 日志时间线才能定是客户端超时值（`DaemonClient.kt`）还是桌面端/relay 建连慢（`crates/daemon`） | L2 |
| P2 | [MOB-41](../cards/MOB-41-reupload-notice-fires-before-the-scope-filter.md) | 重传提示发在范围过滤之前——删掉范围外的照片会弹「正在重传」然后什么也不传 | L2 |
| P3 | [I18N-01](../cards/I18N-01-unnamed-album-fallback-is-hardcoded-chinese.md) | 选相册页空相册名的兜底文案硬编码成中文 | L3 |
| P3 | [SYNC-05](../cards/SYNC-05-asset-meta-src-device.md) | AssetMeta 补来源设备字段，消灭客户端影子状态 | L1 |
| P3 | [BUILD-02](../cards/BUILD-02-toolchain-pin-must-bind-on-ci-too.md) | 核实 CI 侧工具链钉扎是否真的生效 | L2 |
| P3 | [DESK-09](../cards/DESK-09-wizard-swallows-daemon-startup-error.md) | 向导把 daemon 的真实启动错误吞成「没有在 10 秒内就绪」 | L1 |
| P3 | [CI-03](../cards/CI-03-src-tauri-workspace-has-no-fmt-gate.md) | 桌面壳 workspace 没有 fmt/clippy 门禁（⚠️ 要动 workflows，先确认由谁改） | L0 |
| P3 | [BUILD-01](../cards/BUILD-01-local-jdk25-breaks-release-lint.md) | 本机 JDK 25 让 Android release 构建挂 lint（CI 钉 17 不受影响） | L3 |
| P3 | [UI-04](../cards/UI-04-notice-presentation-three-defects.md) | 提示呈现三连：只在总览 / 改名用占布局的条 / 多条堆叠 | L2 |
| P3 | [LINT-01](../cards/LINT-01-android-lint-not-in-ci.md) | Android lint 不在 CI 里跑，红了没人看见 | L3 |
| P3 | [CI-02](../cards/CI-02-e2e-compiles-release-binaries-twice.md) | e2e nightly 两个 job 各自编译一遍 release 二进制（~300 Linux 分钟/月白烧） | L3 |
| P3 | [REL-03](../cards/REL-03-bump-script-silently-skips-desktop-crate-version.md) | bump-version.sh 静默跳过桌面 crate 版本，漂移断言看不见 | L2 |
| P3 | [REL-04](../cards/REL-04-manifest-url-decided-before-mirror-succeeds.md) | manifest 地址在镜像成功前就写死（R2 镜像已撤，本卡是重开镜像的前置） | L2 |
| P3 | 未开卡 | 活动流把机器原文（`asset.replaced_in_place` 等）直接显示给用户，需改文案 | L2 |
| P4（顺手做，不派活） | [CI-04](../cards/CI-04-release-waits-for-the-slowest-platform.md) | 代码①②都已合并（先建草稿、各平台自己上传），不存在权限拍板；剩的是下次你自己发版时顺手拿一次真实 workflow_dispatch/release 验证一下缓存和拆分是否真生效——2026-08-27 用户定为最低优先级 | L1 |

**派活提示**：P1/P2 里的 L0/L1 卡属于「成本在做」，按 AGENTS.md 的派活姿势，
把根因/文件/行号内联进指令即可，不必要求 agent 先通读协议文档。

---

## 二、待你真机验收（代码已合并，就差你动手）

| 卡 | 一句话 | 级别 |
|---|---|---|
| [UX-14](../cards/UX-14-a-failed-retry-is-rendered-as-paused.md) | 暂停 → 继续 → 传输中途关掉 desktop 的 daemon 制造一次连接中断 → 界面**不许**又显示「继续」（应该说它的真实状态：还有 N 张待备份 / 出错了） | L1 |
| [MOB-40](../cards/MOB-40-backup-runs-before-the-user-picks-albums.md) | **卸载重装 → 配对 → 只选那个 11 张的相册 → 全程只传 11 张**；配对到选完相册之间一张都不许传（这一条不过，别的都不用测） | L0 |
| [DESK-10](../cards/DESK-10-export-logs-omits-the-only-logs-that-matter.md) | **复验**（8/26 打回的脱敏漏已补）：①daemon 正常时导出日志 → 9 个文件都在；②daemon 挂着时导出 → 仍出 zip 含 `.err`/`.log`；③grep 整个 zip 不许出现用户名；④`audit.json`/`diag_events.json` 里路径应是 `originals/<8位前缀>…<masked>/…`，看不到完整 hex | L1 |
| [MOB-38](../cards/MOB-38-foreground-catchup-never-fires-on-resume.md) | 从 App 切到相机拍一张再切回来，照片自动传上去 | L0 |
| [UX-13](../cards/UX-13-no-resume-affordance-after-pause.md) | 备份中点「暂停」→ 按钮留在原地变「继续」→ 点它 → 传输接着跑；暂停后杀 App 重开「继续」还在；备份正常跑完「继续」自己消失 | L1 |
| [MOB-32](../cards/MOB-32-calibration-wipes-a-live-backup-session.md) | 大批量备份传到一半打开 App，照片一张都不能丢 | L0 |
| [MOB-37](../cards/MOB-37-reupload-notice-must-survive-a-lost-notification.md) | 关掉通知权限 → 访达删几张已备份照片 → 备份页必须出现「正在重新传回」提示 | L1 |
| [MOB-29](../cards/MOB-29-confirmed-store-lies-between-backups.md) | 访达删照片 → 桌面出警告 + 手机出「正在重传」通知，照片真的传回来 | L1 |
| [MOB-34](../cards/MOB-34-deleted-old-photos-never-re-uploaded.md) | 库里删 3 张老照片 → 不手动干预 → 自己回来，「待备份 K」归零（⚠️ 先看卡里「已知边界」判别法） | L1 |
| [MOB-36](../cards/MOB-36-photos-moved-into-scope-are-never-scanned.md) | 把 1 月的老照片从别的相册移进已选相册 → 不手动干预 → 被备份 | L1 |
| [WATCH-07](../cards/WATCH-07-self-inflicted-duplicate-audit-noise.md) | 备份后活动流不再被「重复」审计刷屏 | L2 |
| [WATCH-03](../cards/WATCH-03-finder-move-orphans-the-photo.md) | Finder 里挪动照片，照片不许消失 | L2 |
| [WATCH-04](../cards/WATCH-04-tolerant-ingest-finder-owns-the-layout.md) | 手拷照片进库目录会被自动收录 | L2 |
| [DESK-08](../cards/DESK-08-activity-each-key-collides.md) | 一次删多张照片，活动记录页不再整块打挂 | L1 |
| [UI-03](../cards/UI-03-mobile-top-titles-removed.md) | 手机端照片/设置页的顶部大标题已删 | L3 |
| [MOB-19](../cards/MOB-19-manual-backup-same-bad-record-crash.md) | 手动「再试一次」与自动备份是同一条管线 | L2 |
| [MOB-09](../cards/MOB-09-one-bad-media-record-kills-batch.md) | 一条坏相册记录不再炸掉整批备份（欠一半：好坏同批未验） | L2 |
| [MOB-13](../cards/MOB-13-triplet-k-never-reaches-zero.md) | 「待备份 K」能归零（有前置，见卡） | L2 |
| [BLOB-01](../cards/BLOB-01-ingest-leaves-a-duplicate-in-the-blob-store.md) | 备份占盘不再翻倍（实测 2.05x → 1.00x） | L2 |
| [E2E-02](../cards/E2E-02-daemon-hello-test-asserts-dead-contract.md) | e2e 门禁已解红，下次打 tag 复核 | L1 |

**已有真机证据的**（2026-08-21 审计，仅供复核）：MOB-32 收尾判据、MOB-30、WATCH-02。

**2026-08-27 验收人已批量关闭**（不要求逐条真机复核）：MOB-28、MOB-31、
MOB-33、MOB-35 → 已移入 `done/`；MOB-43 → 判定不需要实现，已移入 `done/`。

**验收建议**：15 分钟一批过，别攒。

---

## 三、待你拍板（不定就动不了）

**当前为空。**2026-08-27 清空：Apple 签名/公证已确认早就补齐、CI 一直在
真跑,不是待拍板；「两个本机问题」指向的 `local-state.md` 已不
存在、内容丢失，不再挂账——有新的本机问题请直接口述，我会重新建这个文件；
MOB-43 已判定不需要实现,不再是拍板项。

---

## 四、backlog（明确不做或暂缓，agent 不许碰）

| 卡 | 状态 | 备注 |
|---|---|---|
| [MOB-07](../cards/MOB-07-partial-access-global-indicator.md) | 暂不做 | 2026-08-14 拍板 |
| WATCH-05 | 已拍板需要做，实施前重开讨论 | inode 身份缓存（stat 没变就不重算 hash） |
| WATCH-06 | 明确不做 | 卡里写明不要用软链物化视图 |
| MOB-25 / MOB-26 | 暂不做 | 查看页尺寸显示 0×0 / 缺翻页缩放，2026-08-19 拍板 |
| MOB-18 | superseded | 已被 MOB-28 取代，禁止按本卡实施 |
| DESK-11 | 待确认 | 🔵 backlog，若确认露出完整 hex 则升级为 DESK-10 的脱敏漏 |
| UI-05 / UI-06 | 用户暂时接受 | 展示细节问题，低优 |

---

## 五、发版现状（参考，非待办）

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

## 六、相关文档指路

- 规则层（agent 无关）：[`AGENTS.md`](../AGENTS.md) + [`AGENT_PROTOCOL.md`](AGENT_PROTOCOL.md)
- 全量历史账本（只增不减）：[`ROADMAP.md`](ROADMAP.md)
- 方法论教训：[`PROGRESS.md`](PROGRESS.md)
- 交接背景日志（只读，不是待办来源）：[`NEXT.md`](NEXT.md)
- 卡格式规范：`cards/TEMPLATE.md` + `AGENT_PROTOCOL.md` §C.2
