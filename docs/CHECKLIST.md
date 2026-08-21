# P-Pass 对照清单

> **这个文件是干什么的**：把 `ROADMAP.md`（4000 行的全量历史）里跟"现在"有关的
> 部分抽出来，做成你能逐条勾掉的动作清单。
>
> **这个文件是要维护的，不是一次性快照** —— 已进 `CLAUDE.md` 的「每批交付必更
> 文档」清单（PROGRESS + NEXT + ROADMAP + 本文件）。任何一批交付改了卡的状态，
> 这里必须跟着改；漏了就是事故。
>
> 最后更新：**2026-08-21**（`git log -1 --format=%h -- docs/CHECKLIST.md` 是当前版本）
> 全量历史看 [`ROADMAP.md`](ROADMAP.md)，方法论教训看 [`PROGRESS.md`](PROGRESS.md)，
> 交接状态看 [`NEXT.md`](NEXT.md)，任务卡在 [`.claude/cards/`](../.claude/cards/)。

---

## 一、需要你做的：真机验收清单

每条都写了**具体动作**和**期望结果**。结果不符就是没修好，回来说。

### 已经有真机证据的（今天 13:59–14:08 的审计时间线，仅供你复核）

- [x] **12 张的相册 → 进度条分母是 12**（`MOB-31`）
      审计：`13:59:43 backup.finished ingested=12 duplicates=0`
- [x] **备份收尾后中转区干净**（`MOB-32`）
      `du -sh "<库>/.ppf/staging"` = **0B / 0 个文件**
- [x] **照片逐张浮现，不是最后一秒全冒出来**（`MOB-30`）
      12 条 `ingest.new` 分布在 13:59:42–43，不是一个时间点
- [x] **Finder 删照片，索引跟着减**（`WATCH-02`）
      `14:07:29` 5 条 `asset.removed_external`，索引 12 → 7
- [x] **占盘不再翻倍**（`BLOB-01`）
      `.ppf/blobs/data` = 0B；库 7.2M / originals 4.6M

### 还欠验收的（请你动手）

- [ ] **`DESK-08` 活动流不再打挂**
      动作：Finder 里一次删 3 张以上照片 → 看桌面端「活动记录」页
      期望：N 条删除记录都在，浏览器控制台**没有** `each_key_duplicate`
- [ ] **`UI-03` 手机端顶部大标题已删**
      动作：手机上打开「照片」和「设置」两页
      期望：顶部没有【全家的照片】【设置】那两行大字，第一行照片/英雄卡上移，
      不贴状态栏
- [ ] **`MOB-32` 中途打开 App 不丢照片**（本轮最重的一条）
      动作：手机上开始一次**较大批量**的备份，传到一半时**打开 App**（触发漂移校准）
      期望：照片数全部到位；收尾后 `du -sh "<库>/.ppf/staging"` = 0
      ⚠️ 两条别当失败信号：①白板环境没有存量孤儿，**不会**看到
      `MOB-32: 回收 staging 孤儿` 那行日志；②新 APK 的校准不再发 `begin`，
      真机踩不到 `begin` 保活那条路（旧 APK 的形状由集成测试钉死）
- [ ] **`WATCH-03` Finder 挪动照片，照片不许消失**
      动作：把 `originals/` 里的一张照片拖到同一库内的另一个目录
      期望：桌面照片墙里它还在（只是换了住址），索引行数不变
- [ ] **`WATCH-04` 手放进去的照片会被收录**
      动作：直接往 `originals/` 里拷一张照片（不经手机）
      期望：几秒内出现在照片墙，归属显示为**本机**，按拍摄时间挂入
- [ ] **`MOB-19` 手动备份不再是第二条代码路径**
      动作：手机失败红卡上点「再试一次」
      期望：走的是同一条管线，不再有独立的手动逻辑
- [ ] **`MOB-09` 坏记录不炸整批**（欠一半）
      动作：造一条坏 MediaStore 记录 + 一条好记录**同批**
      期望：日志 `skipped 1/2`，好的那张照样备份成功
      现状：只验过 `skipped 1/1`（单独一条坏记录）
- [ ] **`MOB-13` 「待备份 K」能归零**
      前置：升级后先手动按一次备份，补齐文件级记录
      动作：复制一张已备份的照片到相册
      期望：待备份数字回到 0，不是永远挂着
- [ ] **`MOB-28` 区分「重启」与「被清」**（8/20 已端到端验过，复核用）
      动作：force-stop App 再打开
      期望：提示中断，**不静默恢复**

---

## 二、等你拍板的决定（不定就动不了）

- [ ] **`MOB-29`「已备份」数字口径** —— 二选一：
      - **(A) 只数库里真有的**：诚实。数字会从 188 掉到 3，需要配一句
        「另有 N 张已按你的要求删除」。**我倾向这个。**
      - **(B) 数「已交代过的」** = 库里有的 + 墓碑里的：数字稳定，但仍然误导。

      ⚠️ 今天真机证实了这条卡的必要性：14:07 你手动删的 5 张，14:08 那轮
      **原样全回来了**（逐个查文件名，索引里每个 1 行）。
- [ ] **桌面端「更改…」按钮** —— 点下去屏幕上**实际发生了什么**？
      - 读法 A：根本没弹窗（弹到主窗口后面了）→ Tauri macOS 窗口激活问题
      - 读法 B：弹了，但点目录没反应，点「Open」才发现能导航 → `defaultPath`
        指向不存在的目录导致面板初始状态怪

      修法完全不同，不想瞎猜。复现不用动首次向导：设置页的
      「更改照片库位置…」走的是**同一个** `openDialog`。
- [ ] **向导第三步「设为常驻服务」** —— 你是跳过了，还是点了没成？
      现状：`launchctl` 里**没有** P-Pass 的常驻项，daemon 是一次性 spawn 起来的。
      代码注释写着「基础服务不该手动启动、不该会停」。如果是点了没成，
      那是真问题（开机不自启、崩了不恢复），要开卡。
- [ ] **旧数据副本要不要删** ——
      `~/P-Pass NAS.bak-blob01-20260820-1615`（1.1G，含你 549M 照片）。
      上次清场时故意留给你自己删的，daemon 不认识它。
- [ ] **`SITE-02` 三篇博文** —— 草稿完成，待你审稿后发布。

---

## 三、已完成（不用你做，供对照）

### 本轮（2026-08-21）

| 卡 | 事情 | 级别 |
|---|---|---|
| `MOB-32` | 校准清空活会话 → 照片传上来被静默丢弃（一次丢 185 张 / 547MB） | **L0** |
| `MOB-30` | 入库跟着上传走，不再攒到 commit；顺带解掉断线整批重传 | L2 |
| `MOB-31` | 界面从五条通道的历史终态里随机挑一条 | L2 |
| `WATCH-02` | 删除对账被一个斜杠废掉（`LIKE 'originals//%'` 命中 0 行） | L2 |
| `WATCH-03` | Finder 挪动照片导致索引删行、照片凭空消失 | L2 |
| `WATCH-04` | 宽容入库：`originals/` 是你的目录，手放的文件归本机 | L2 |
| `DESK-08` | 活动流用时间戳当 each key，同毫秒的审计撞键把整块打挂 | L1 |
| `UI-03` | 手机端删掉照片页/设置页的顶部大标题 | L3 |

### 之前几轮

`BLOB-01`（占盘 2.05x → 1.00x）· `MOB-28`（区分重启/被清）· `MOB-19`（备份只有一条管线）·
`MOB-09`（坏记录隔离）· `MOB-13`（待备份 K 归零）· `E2E-02`（e2e 门禁解红）· `MOB-27`（监听与干活分家）

---

## 四、待做 to-do（按优先级）

| # | 卡 | 事情 | 级别 | 阻塞在 |
|---|---|---|---|---|
| 1 | `MOB-29` | 墓碑 + 客户端常驻提示（删掉的照片不再自动回来） | L1 | **你的数字口径决定** |
| 2 | `WATCH-07` | 每批备份后活动流被 N 条 `ingest.duplicate` 刷屏 | L2 | 无，可做 |
| 3 | — | 桌面端「更改…」选目录交互 | ? | **你补一句现象** |
| 4 | `SYNC-05` | `AssetMeta` 补 `src_device`，消灭客户端影子状态 | L1 | 无，可做 |
| 5 | — | 活动流把 `asset.replaced_in_place` 这类**机器串**直接显示给用户 | L2 | 还没开卡 |
| 6 | `WATCH-05` | inode 身份缓存（stat 没变就不重算 hash） | L2 | **你说实施前重开讨论** |
| 7 | `BUILD-02` | 工具链钉在本地了，但 CI 侧能不能钉住**没核实**（action 可能导出 `RUSTUP_TOOLCHAIN` 盖掉 toml） | L2 | 无，可做 |
| 8 | `BUILD-01` | 本地 JDK 25 让 Android release 构建挂在 lint（CI 钉 17 不受影响） | L3 | 无，可做 |

`WATCH-05` 的账：`stat` 4.6 µs/张 vs 全量 hash 2.8 ms/张 = **620 倍**（203 张
真实照片 / 570MB 实测）。目标量级几万张，这条是必做的。

---

## 五、backlog（你明确说过先不做）

| 卡 | 事情 | 备注 |
|---|---|---|
| `WATCH-06` | 相册 = 目录 | 卡里写明**不要用软链**物化视图 |
| `MOB-07` | 部分授权全局提示（tab 红点） | 用户 2026-08-14：「现在先不做」 |
| `MOB-25` | 查看页尺寸显示 `0×0` | 2026-08-19 拍板暂不做 |
| `MOB-26` | 查看页缺基础手势，应改用成熟方案 | 2026-08-19 |
| `MOB-18` | force-stop 检测 | 已被 `MOB-28` 取代 |

**范围红线**：文件备份 / 文件同步整个不在范围内，**只做图片**。

---

## 六、环境与命令速查

### 当前环境（2026-08-21 14:35）

```
库：      ~/Pictures/P-Pass 家庭照片库
NodeId：  1f1d1e386aae7d33a352b9c620f95a3efa5543d0eacc2420c43b43ec81bbce32
手机：    SM-S9210，已配对（devices 里叫 SM-S9210）
索引：    18 行 / originals 18 个文件 / staging 0 字节
旧副本：  ~/P-Pass NAS.bak-blob01-20260820-1615（1.1G，等你删）
daemon：  一次性 spawn（launchd 里**没有**常驻项，见第二节）
```

### 你可能要用的命令

```bash
# 中转区必须是 0 —— 留下的每个字节都是丢掉的照片
du -sh "$HOME/Pictures/P-Pass 家庭照片库/.ppf/staging"

# 索引行数
sqlite3 "file:$HOME/Pictures/P-Pass 家庭照片库/.ppf/index.sqlite?mode=ro" \
  "select count(*) from asset;"

# 审计时间线（最近 25 条）
sqlite3 -column -header "file:$HOME/Pictures/P-Pass 家庭照片库/.ppf/index.sqlite?mode=ro" \
  "select datetime(ts/1000,'unixepoch','localtime') t, action, coalesce(detail,'') d
   from audit_log order by ts desc limit 25;"

# 本地全量门禁
just ci                                  # fmt + clippy + 全仓测试 + 架构检查
just android-test                        # Android 单测
cd apps/desktop && npx vitest run        # 桌面前端测试
```

### 远端流水线（需要你先登录 gh）

`gh` 没有认证态，agent 触发不了 `workflow_dispatch`。你先跑 `gh auth login`，
然后这三条我或你都能跑：

```bash
# 双平台正式产物（macOS .app + Android APK），走 dispatch 不烧 tag
gh workflow run release.yml -f platforms=android,macos

# 全量 e2e 门禁（平时只在 nightly / tag 跑）
gh workflow run e2e.yml

# 盯今天 8 个 commit 触发的 ci-rust / ci-android / ci-desktop
gh run list --limit 12
```

⚠️ 按仓库 tag 纪律，测试构建**只用 `workflow_dispatch`**，不给它打真 tag
（8/9 一个周末烧掉八个 test tag 是反面教材）。

### 凭据与构建归属（2026-08-21 定调）

> 「构建的任务和需要的账号证书，都只在 GitHub，其它本地不保留，本地能跑的就跑
> 就好了。」

**本地只跑跑得动的**：`just ci` · Android debug APK + 单测 · 桌面 dev 壳 + vitest。
**本地 release 构建不是目标** —— 下面这两条是"无凭据路径"的**预期行为，不是待修
的 bug**：

| 平台 | 本地跑出来的 | 说明 |
|---|---|---|
| macOS | `.../bundle/macos/P-Pass.app` 出得来，updater 的 `.tar.gz` 签名步报错 | 缺 `TAURI_SIGNING_PRIVATE_KEY`。`.app` 本身没问题，内置 `ppf-daemon` 已核对含 MOB-32 + DESK-08 |
| Android | `app-release-unsigned.apk` | **未签名装不上**。真机继续用 debug APK |

**要可安装的正式产物就走 CI**：`gh workflow run release.yml -f platforms=android,macos`。

#### GitHub Secrets 实况（仓库历史记录里核实的，不是猜的）

| 凭据 | 状态 | 证据 |
|---|---|---|
| `ANDROID_KEYSTORE_BASE64/ALIAS/PASSWORD` | ✅ 已配 | `v0.2.1-test.2`（run 30950901275）**Android signed APK** job success |
| `UPDATE_SIGNING_KEY` | ✅ 已配 | 同一次 **Sign update manifest** step success |
| `APPLE_CERT_P12` / `APPLE_NOTARY_*` / `APPLE_TEAM_ID` | ❌ 未配 | T-071 原话「无凭据路径 codesign 步干净跳过」「凭据路径待 H-02」 |
| `VT_API_KEY` / `CLOUDFLARE_*` | ⚠️ 无记录 | 门控写的是缺就跳过 |

所以**现在跑 release.yml**：Android 出**签名 APK 能直接装**；macOS 出 `.app`/`.dmg`
但**未签名未公证**，家人装的时候「右键 → 打开」过 Gatekeeper。

- [ ] **补 Apple 签名（需要你本人，可选）** —— 操作单
      [`docs/runbook/h02-apple-signing.md`](runbook/h02-apple-signing.md)，
      10–15 分钟，前提是 Apple Developer Program（$99/年）。
      runbook 自己写着：没有会员就先不做，只在公开发布前是硬性的。
      ⚠️ 导出证书需要钥匙串的交互授权弹窗，**agent 代不了**。
- [ ] **确认 `release-signing` 审批门** —— macOS job 挂了
      `environment: release-signing`。如果你加过 required reviewer，那个 job
      会停下来等你点批准。

### 测试规模现状

```
Rust        314 / 314
Android     253 / 253
桌面前端     18 /  18   （今天从 8 涨到 18）
```
