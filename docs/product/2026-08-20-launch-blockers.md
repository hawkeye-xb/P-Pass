# 上线阻塞清单（2026-08-20 实测盘点）

> 用户问："我们还有什么必做才能上线的吗？"
> 本文只列**实测确认**的项，每条带证据。不是读卡抄的。

## 盘点方法

- `just ci`（fmt + lint + test + arch-check）→ **全绿**
- Android `:app:testDebugUnitTest --rerun-tasks` → **234/234**
- 在用户真机（RFCX1040SNE / 0.3.4(9)）上验监听链路
- 在用户真机（macOS，`/Users/zhaowenli/P-Pass NAS`）上量占盘
- 逐张翻 `.claude/cards/*.md`（未完成 11 张）+ ROADMAP 挂账段

**结论：代码健康度没问题，挡上线的是三件功能缺口 + 两件发布机制。**

---

## P0 — 必须做，不做会被真实用户直接撞到

### ① blob store 不回收，占盘翻倍　【实测确认】

用户机器实测：

```
originals    549M   ← 照片库（真正要留的）
.ppf/blobs   554M   ← iroh blob store（同一批照片的第二份）
.ppf/thumbs   22M
────────────────
合计         1.1G   → 占盘 = 照片本身的 2.05 倍
```

`crates/daemon/src/backup.rs` 的 ingest 流程是
「blob 落 store → `export_to(staging)` → `ingestor.ingest()` 进库」，
`crates/transport` 里**没有任何 blob 删除路径**（grep 过 delete / gc /
untag，零命中），所以 blob 永久留在 store 里。

对一个**备份产品**来说这是硬伤：用户备 50G 照片要占 100G。ROADMAP 挂账里
写的「blob-store GC」就是这条，但当时没有量级数据，容易被当成优化项。

**必做**。ingest 成功之后删掉对应 blob（或改成 ingest 直接从 blob store
取、不落第二份）。

### ② 手动备份仍会被一条坏 MediaStore 记录炸掉整批　【MOB-19，卡已写未实施】

MOB-09 修的是自动备份链路（`BackupWorker`），卡面范围写死只准动那里。
手动备份链路 `BackupUiStateHolder` 是**同一形状的裸 map + open**，同一条
坏记录同样炸整批。

现网怎么产生坏记录：文件管理器删了文件但 MediaStore 行没同步清理、云相册
占位文件、外部存储卸载、第三方 App 写坏的行。用户看到的现象是「点了备份
就转圈然后失败，每次都失败」。

**必做**，改法照搬 MOB-09（`buildCandidates` 逐条隔离 + 探针 open）。

### ③ 桌面照片墙不跟随变化　【DESK-06，卡已写未实施，用户 8/13 已反馈过】

用户原话："移动端订阅状态有了，我们 desktop 照片反而没有同步？？？我本地
finder 删除了照片，移动端都体现出来了，我们桌面端反而没有"

根因已定位：桌面 `onDaemonEvent` 只对 `activity.appended` / `device.changed`
重置照片墙缓存，**漏了 `timeline.invalidated`**，于是照片墙永远停在首次
加载的快照，且没有手动刷新入口。附带问题：活动记录页把
`asset.removed_external originals missing: <长路径>` 这类机器原文直接显示
给用户看。

**必做**。这是"电脑端看起来坏了"的第一印象问题，改动只在
`apps/desktop/src/App.svelte`。

---

## P1 — 发布机制，不做会卡住"打 tag 发版"这个动作本身

### ④ e2e 门禁常红，每次打 tag 都会撞　【E2E-02，卡已写未实施】

`DaemonHelloTest` 第一步断言配对码必须带 `a=`，而 H-10b（2026-08-08）
已经把 `&a=` 从配对码里删掉了（`crates/daemon/src/pairing.rs` 注释写得
很清楚）。用户打 `v0.3.3-test.7` 时就红过一次，daemon 日志一切正常，
迷惑性很强。

**必做**，否则每次发版都要人工判断"这个红能不能忽略"——那等于没有门禁。

### ⑤ 站点与 DNS 未落地

- `SITE-02` 三篇博文草稿完成，**等你审稿**才能去 draft 发布
  （本轮又加了一篇《我们自己造了个队列，而系统本来就有一个》，也在等审）
- `p-pass.hawkeye-xb.com` 的 CNAME 还指向旧占位 `p-pass-landing.pages.dev`，
  要改指 `hawkeye-xb.github.io`（CF zone `65dec62bc61b00e5d22fedc40b774bdc`）
- `SITE-01` 挂账：Pages 三路由 200 + Lighthouse ≥90 未实测

如果"上线"包含对外发声（ROADMAP M4 的 r/selfhosted post），这条是前置。

---

## P2 — 有明确缺口，但可以带着上线

| 项 | 现状 | 带病上线的后果 |
|---|---|---|
| `MOB-13` 待备份 K 归零 | 代码已合，**真机复验未做**（需先手动按一次备份补齐文件级记录） | 三元组数字可能显示不准，不影响备份正确性 |
| `MOB-09` 真机验收 | 本轮探针撞到了 `skipped 1/1 unreadable media record(s)` 且无 ENOENT 重试，但没做「坏记录 + 好记录同批」的对照 | 逻辑已由单测 + 反证锁住，风险低 |
| `SYNC-05` src_device | 卡已写未实施。「仅本机/家人的」筛选器现在读客户端自攒的影子状态 | 换机/重装后筛选器会算错归属 |
| `SYNC-04` 前台常驻订阅 | 卡已写未实施 | 手机端时间线要靠下拉/重进刷新 |
| `ICON-02` 图标库迁移 | 代码已合，真机观感挂账 | 纯观感 |
| Windows | release.yml 有 `windows-x64` job，但**从没在真 Windows 上跑过**（挂账「Windows smoke」） | 如果首批用户里有 Windows，等于盲发 |
| 视频缩略图 | daemon 侧生成失败（`thumb_state=2` → 灰占位），M2 就记了 | 视频在墙上是灰块 |
| `MOB-25` `0×0` 尺寸 | backlog | 部分资产显示尺寸为 0 |
| `MOB-26` 查看器翻页 | backlog | 大图不能左右滑 |
| `BucketScreen.kt:81` lint 红 | `ProduceStateDoesNotAssignValue`，CI 不跑 lint 所以一直没暴露 | 潜在的 Compose 状态 bug，值得看一眼 |
| 四条备份通道可并行 | 四个独立 unique name，理论上能同时跑两个 BackupWorker 扫同一水位 | 偶发重复推字节，浪费带宽不丢数据 |

---

## P3 — 产品门槛，不是代码

ROADMAP 上还挂着两道**用户自己定的闸**，跟代码无关：

- M2 gate：**一周真实家庭狗粮，备份完成率 100%**
- M4 gate：**5–10 户私测两周**

这两条是"敢不敢让别人用"的判断，我给不了结论。

---

## 建议顺序

1. **①blob GC** —— 唯一一条"用户会因此卸载"的，而且是 Rust 侧独立改动
2. **③DESK-06** —— 第一印象问题，改动最小（单文件）
3. **②MOB-19** —— 改法现成，照搬 MOB-09
4. **④E2E-02** —— 一行断言，解开发版门禁
5. 然后再谈 ⑤ 和 P3 的两道闸

①②③④ 四条都有现成卡或明确根因，不需要再调研。
