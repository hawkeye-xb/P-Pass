# DESK-09 向导把 daemon 的真实启动错误吞成「没有在 10 秒内就绪」　级别 L1

> 🟡 代码已合并（commit 1e1359f），等真机验收
> 级别：L1 · 阻塞：无

## 问题

桌面向导第 2 步（电源检查 → 设为常驻服务）启动 daemon 失败时，界面只说：

> 启动后台服务失败：Error: 后台服务没有在 10 秒内就绪

这句话**不含任何可行动信息**——用户不知道是端口占用、库路径没权限、还是别的。
而 daemon 进程**自己已经把精确原因打在 stderr 上了**，只是没人收。

真实现场（2026-08-25，验收人真机）：用户误装了旧版本（0.3.0）的包，
daemon 直接吐出

```
Error: migration: migration 2 was previously applied but is missing in the resolved migrations
```

= 「你这个旧 daemon 打不开被新版迁移过的索引库」。这是**精确、可行动**的错误
（换回新版即可），但用户看到的是「没有在 10 秒内就绪」，于是花了很长时间
在错误的方向上排查（先怀疑 dmg 布局、只读卷、Gatekeeper）。

**这条正好撞在本项目自己的产品规则上**：`assets/design/tokens.json` 的
rules 写着「No jargon stands alone — every term gets a plain sentence」，
而这条提示连术语都没有，只有一个超时。

## 期望行为

- 启动失败时，界面必须显示 **daemon 实际输出的那一行**（原文附在超时说明
  之后即可，不必翻译成中文——原文可搜索、可贴给开发者）。
- 对**已知的几类**失败给一句人话 + 一个动作：
  - 数据库迁移不兼容（`migration ... missing in the resolved migrations`）
    → 「这个版本比你的照片库旧。请装回新版本。」
  - 端口被占（daemon 已有人话错误，DAE-03 做过）→ 原样透出
  - 库目录不可写 → 「选一个你有写权限的文件夹。」
- 超时**不是错误原因**，它只是「我们等不下去了」——文案不许把它当成结论。

## 验收标准

- [x] 单测：给一个必然启动失败的 sidecar（stderr 写已知错误串）→ 界面文本
  **包含该错误串**
- [x] 单测：迁移不兼容那类错误 → 界面出现「装回新版本」这句人话
- [x] 反证：去掉 stderr 透出 → 上一条变红
- [ ] 真机：拿一个旧版本包打开新版库，界面必须能让人一眼看懂「版本装反了」

## 范围

- 只准动：桌面壳启动 daemon 的那条路径与其错误呈现（`apps/desktop/src/**`
  与必要的 Tauri 命令），以及相关测试
- 不准动：daemon 自身的错误文本（它已经足够精确）；10 秒这个超时值本身
  （超时长短不是本卡的问题）

## 阻塞与依赖

无。

---

## 备注

发现经过：2026-08-25 验收人测 `v0.4.0-test.1` 时，从 GitHub `/releases`
顶部下载，拿到的却是 **0.3.0** 的包（prerelease 拿不到「Latest」徽章，
顶部下载区只给正式版——这个行为是刻意的，正是它保证家人设备不会拿到测试
版，但它让「测试版必须直接进 tag 页」成了一个必须知道的陷阱）。装上后
两个症状：dmg 没有拖拽布局（那是 8/6 构建，布局修复 `b480244` 是 8/8 落地
的），以及本卡这条。**两个症状同一个根因，但错误提示没能把人指到根因上。**

顺带记一条给未来的自己：排查这个问题时，直接在只读卷上跑
`P-Pass.app/Contents/MacOS/ppf-daemon --version` 就把真错误拿到了。
沿着「界面说超时」去猜只读卷/Gatekeeper/TCC 全是弯路。

---

## 实施记录（1e1359f）

### 改了什么

- `apps/desktop/src-tauri/src/daemon_logs.rs`（新）——日志读取层：plist 解析
  （`StandardOutPath` / `StandardErrorPath`，**不硬编码 `~/Library/Logs`**）、
  按偏移读新增字节、从新增输出里挑错误行（原文，不截断不翻译）。
- `apps/desktop/src-tauri/src/lib.rs`——两个新命令：`daemon_err_offset`
  （启动**前**记 stderr 长度）、`daemon_startup_error(offset)`（超时后只读
  新增那段，返回 `captured` / `line` / `err_path`）。
- `apps/desktop/src/lib/daemonStartup.js`（新）——界面文案组装：超时不再当
  结论、daemon 原文照登、已知失败给一句人话 + 一个动作。
- `apps/desktop/src/Wizard.svelte`——`finishSetup` 接上以上两个命令；错误块
  加 `whitespace-pre-line`（多行不许挤成一坨）。

### 为什么要记「启动前的偏移」

launchd 的 `StandardErrorPath` 是 **append** 的、跨多次运行累积。直接 tail
整个文件，会把几天前的旧错误当成这次的原因——跟「导出包里只有一条四天前的
事件」是同一种病。所以启动前记长度，超时后只看新增字节；一个字节都没新增
就明说「没有捕获到后台服务的新错误输出」，绝不拿旧内容顶上。

### 分类口径

| 错误 | 人话 + 动作 |
|---|---|
| `... missing in the resolved migrations` / `migration N was previously applied` | 「这个版本比你的照片库旧……请装回新版本（测试版要从对应 tag 页下载）」 |
| 端口占用（`already in use` / `EADDRINUSE`） | 不覆盖，原样透出（daemon 自己的错误已经是人话） |
| `Read-only file system` / `Permission denied` / `Operation not permitted` | 「回到第 1 步，选一个你有写权限的文件夹」 |
| 不认识的 | 只给原文——宁可少一句猜测，也不能拿假解释盖住真错误 |

### 证据

`cd apps/desktop && pnpm test`：

```
 Test Files  4 passed (4)
      Tests  31 passed (31)
```

其中本卡 7 条（`src/lib/daemonStartup.test.js`）：含原文、含「装回新版本」、
「超时不当结论」（断言文本里**不许**再出现「没有在 10 秒内就绪」）、库目录
不可写、端口占用原样透出、没捕获到新输出时明说、未知错误照登原文。

`cd apps/desktop/src-tauri && cargo test --lib`：`17 passed`（其中日志层 7 条：
plist 路径解析 / 无 key 时如实读不到 / 只读新增字节 / 事故原文行被原样挑出 /
无标记退回最后一行 / 长 hex 脱敏 / zip 往返）。

### 反证（真跑，红输出摘录）

把 `startupFailureMessage` 里透出 daemon 原文的那一行 push 删掉（= 退回
「不透出 stderr 原文」）：

```
 ❯ src/lib/daemonStartup.test.js (7 tests | 5 failed) 8ms
     × 界面文本包含 daemon 输出的那一行原文 5ms
     × 迁移不兼容那类错误给出「装回新版本」这句人话 1ms
     × 库目录不可写 → 让人换个有写权限的文件夹 1ms
     × 端口被占用 → 不覆盖 daemon 已有的人话错误，只原样透出 1ms
     × 不认识的错误也照登原文（不拿猜测盖住真错误） 0ms

AssertionError: expected '后台服务没能起来（我们等了 10 秒就不等了——超时只是我们等不下去了，不…'
  to contain 'migration 2 was previously applied bu…'
```

判据不是恒真式。改回后 31 passed。

### 还差什么（真机）

拿一个旧版本包打开新版库（让 daemon 因迁移不兼容启动失败）→ 向导第 3 步
点「完成」，界面必须出现 `migration ... missing in the resolved migrations`
这行原文 + 「装回新版本」那句人话。只有真机能证伪：本机测到的是文案组装与
日志读取两段，真机测的是这两段在真的启动失败时确实被走到。
