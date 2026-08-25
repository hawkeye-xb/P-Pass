# P-Pass 待办对照清单

> **这个文件只是索引。** 任务的完整描述（问题 / 期望行为 / 验收标准）在
> [`.claude/cards/`](../.claude/cards/) 的任务卡里，卡是**唯一事实源**。
> 卡的状态变了，本文件必须跟着改（已进 CLAUDE.md「每批交付必更文档」清单）。
>
> 本机路径 / 设备 / 本地命令不在这里——它们在 `.claude/local-state.md`
> （开发机本地文件，不进 git）。
>
> 最后更新：**2026-08-25**

---

## 一、待你真机验收（代码已合并，就差你动手）

每条点了卡链接能看到具体的验收动作和期望结果。

| 卡 | 一句话 | 级别 |
|---|---|---|
| [DESK-09](../.claude/cards/DESK-09-wizard-swallows-daemon-startup-error.md) | 拿旧版本包打开新版库（daemon 因迁移不兼容起不来）→ 向导界面必须出现 `migration ... missing in the resolved migrations` 这行原文 + 「装回新版本」那句人话 | **L1** |
| [DESK-10](../.claude/cards/DESK-10-export-logs-omits-the-only-logs-that-matter.md) | ①daemon 正常时点「导出日志」→ 包里 9 个文件都在；②daemon 挂着时点导出 → 仍出 zip 且含 `.err`/`.log` 与版本号；③grep 整个 zip 不许出现你的用户名 | **L1** |
| [MOB-32](../.claude/cards/MOB-32-calibration-wipes-a-live-backup-session.md) | 大批量备份传到一半打开 App，照片一张都不能丢 | **L0** |
| [MOB-29](../.claude/cards/MOB-29-confirmed-store-lies-between-backups.md) | 访达删照片 → 桌面端出警告 + 手机端出「正在重传」通知，且照片真的被传回来（顺带：手机「已备份」数字不再在两次备份之间说谎） | **L1** |
| [WATCH-07](../.claude/cards/WATCH-07-self-inflicted-duplicate-audit-noise.md) | 备份后活动流不再被「重复」审计刷屏（同一文件复检不记审计） | L2 |
| [WATCH-03](../.claude/cards/WATCH-03-finder-move-orphans-the-photo.md) | Finder 里挪动照片，照片不许消失 | L2 |
| [WATCH-04](../.claude/cards/WATCH-04-tolerant-ingest-finder-owns-the-layout.md) | 手拷照片进库目录会被自动收录 | L2 |
| [DESK-08](../.claude/cards/DESK-08-activity-each-key-collides.md) | 一次删多张照片，活动记录页不再整块打挂 | L1 |
| [UI-03](../.claude/cards/UI-03-mobile-top-titles-removed.md) | 手机端照片/设置页的顶部大标题已删 | L3 |
| [MOB-19](../.claude/cards/MOB-19-manual-backup-same-bad-record-crash.md) | 手动「再试一次」与自动备份是同一条管线 | L2 |
| [MOB-09](../.claude/cards/MOB-09-one-bad-media-record-kills-batch.md) | 一条坏相册记录不再炸掉整批备份（欠一半：好坏同批未验） | L2 |
| [MOB-13](../.claude/cards/MOB-13-triplet-k-never-reaches-zero.md) | 「待备份 K」能归零（有前置，见卡） | L2 |
| [MOB-28](../.claude/cards/MOB-28-distinguish-interruption-and-ask-before-recovering.md) | force-stop 后打开 App 提示中断、不静默恢复（已验过，复核） | L2 |
| [BLOB-01](../.claude/cards/BLOB-01-ingest-leaves-a-duplicate-in-the-blob-store.md) | 备份占盘不再翻倍（实测 2.05x → 1.00x） | L2 |
| [E2E-02](../.claude/cards/E2E-02-daemon-hello-test-asserts-dead-contract.md) | e2e 门禁已解红，下次打 tag 复核 | L1 |

### 已有真机证据的（2026-08-21 审计时间线，仅供复核）

- [x] MOB-31：12 张相册进度条分母 = 12
- [x] MOB-32 收尾判据：备份结束后中转区 0 字节
- [x] MOB-30：照片逐张浮现，不是最后一秒全冒出来
- [x] WATCH-02：Finder 删照片，索引跟着减

## 二、等你拍板（不定就动不了）

| # | 事项 | 选项 / 卡 |
|---|---|---|
| 1 | 两个本机问题（「更改…」按钮现象、常驻服务向导） | 见 `.claude/local-state.md`（本机文件） |

## 三、待做队列（无阻塞，可直接开工）

| # | 卡 | 一句话 | 级别 |
|---|---|---|---|
| 1 | [SYNC-05](../.claude/cards/SYNC-05-asset-meta-src-device.md) | AssetMeta 补来源设备字段，消灭客户端影子状态 | L1 |
| 2 | [BUILD-02](../.claude/cards/BUILD-02-toolchain-pin-must-bind-on-ci-too.md) | 核实 CI 侧工具链钉扎是否真的生效 | L2 |
| 3 | [BUILD-01](../.claude/cards/BUILD-01-local-jdk25-breaks-release-lint.md) | 本机 JDK 25 让 Android release 构建挂 lint（CI 钉 17 不受影响） | L3 |
| 4 | [MOB-33](../.claude/cards/MOB-33-four-channels-can-run-two-backups-in-parallel.md) | 四条备份通道可并行跑两个 BackupWorker，重复推字节（浪费不损坏） | L2 |
| 5 | [LINT-01](../.claude/cards/LINT-01-android-lint-not-in-ci.md) | Android lint 不在 CI 里跑，红了没人看见 | L3 |
| 6 | [CI-02](../.claude/cards/CI-02-e2e-compiles-release-binaries-twice.md) | e2e nightly 两个 job 各自编译一遍 release 二进制（~300 Linux 分钟/月白烧） | L3 |
| 7 | [REL-03](../.claude/cards/REL-03-bump-script-silently-skips-desktop-crate-version.md) | bump-version.sh 静默跳过桌面 crate 版本，漂移断言看不见 | L2 |
| 8 | [REL-04](../.claude/cards/REL-04-manifest-url-decided-before-mirror-succeeds.md) | manifest 地址在镜像成功前就写死（R2 镜像已撤，本卡是重开镜像的前置） | L2 |
| 9 | [MOB-34](../.claude/cards/MOB-34-deleted-old-photos-never-re-uploaded.md) | 库里删掉的老照片永不重传（水位挡住扫描），「待备份 K」永远归不了零 | **L1** |
| 10 | [MOB-35](../.claude/cards/MOB-35-interruption-prompt-freezes-foreground-sync-too.md) | 中断待确认时连前台同步也被冻住（一个 return 挡了两件事） | **L1** |
| 11 | 未开卡 | 活动流把机器原文（`asset.replaced_in_place` 等）直接显示给用户，需改文案 | L2 |

## 四、backlog（你明确说过先不做）

| 卡 | 一句话 | 备注 |
|---|---|---|
| [MOB-07](../.claude/cards/MOB-07-partial-access-global-indicator.md) | 相册部分授权的全局提示 | 2026-08-14：「现在先不做」 |
| WATCH-05 | inode 身份缓存（stat 没变就不重算 hash，省 620 倍） | 已拍板「需要做」，实施前重开讨论 |
| WATCH-06 | 相册 = 目录 | 卡里写明不要用软链物化视图 |
| MOB-25 / MOB-26 | 查看页尺寸显示 0×0 / 缺翻页缩放 | 2026-08-19 拍板暂不做 |
| MOB-18 | force-stop 检测 | 已被 MOB-28 取代 |
| [SITE-02](../.claude/cards/SITE-02-first-posts.md) | 首批三篇博文（草稿已完成） | 2026-08-25 降级：「优先级没这么高，回头统一审稿」——不再催审，不算上线阻塞 |

**范围红线**：文件备份 / 文件同步整个不在范围内，**只做图片**。

---

## 五、发版与流水线

正式产物走 CI：`gh workflow run release.yml -f platforms=android,macos`
（Android 出签名 APK；macOS 未签名，「右键 → 打开」过 Gatekeeper）。
调管线只用 workflow_dispatch，不打测试 tag（tag 纪律见根目录 CLAUDE.md）。

Apple 签名补齐需你本人操作（可选）：`docs/runbook/h02-apple-signing.md`。

**Secrets 实况（2026-08-25 核实）**：`CLOUDFLARE_API_TOKEN` /
`CLOUDFLARE_ACCOUNT_ID` / `ANDROID_KEYSTORE_*` / `UPDATE_SIGNING_KEY` /
`APPLE_*` **全部在位**。旧文档里「等用户加 CLOUDFLARE_API_TOKEN」的挂账已作废。

**触发节奏（2026-08-25 用户拍板「我需要构建的时候再构建」后的现状）**：

| 流水线 | 自动触发 | 手动 |
|---|---|---|
| ci-rust / ci-android / ci-desktop / site build | push（paths 门控） | — |
| e2e | nightly 03:30 + tag + PR 打标签 | dispatch |
| **artifacts（dogfood 裸二进制）** | **仅 Linux** | **macOS / Windows 只手动** |
| release（签名公证可分发包） | tag `v*` | dispatch（platforms 可选） |
| ci-workers | push(infra/workers/**)，**不含自身** | dispatch |

**ci-workers 审批门**：`environment: workers-prod` 让部署 job 停在 `Waiting`
等 owner 批准——**不占 runner、不计费**，挂 30 天自动作废。当前 3 个 Waiting
run 全部由「改 ci-workers.yml 自己」触发，worker 代码零改动 → **paths 已在
2026-08-25 去掉自身**，不会再堆。存量那 3 个：旧的 Cancel，最新一个可批一次
以验证部署链路。

## 六、相关文档

- 全量历史：[`ROADMAP.md`](ROADMAP.md)（只增不减的账本）
- 方法论教训：[`PROGRESS.md`](PROGRESS.md)
- 交接状态：[`NEXT.md`](NEXT.md)
- 卡格式规范：`.claude/cards/TEMPLATE.md` + `docs/AGENT_PROTOCOL.md` §C.2
