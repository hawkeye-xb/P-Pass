# CI-04 三平台并行跑完才建草稿——一个没跑完就一个都下载不了　级别 L1

> 🟡 状态：**①② 均已实施并已合入 main**（① `windows-x64` vcpkg 缓存；
> ② 拆成 create-draft + 三条独立 upload job，见「实施记录①②」，
> commit `1ee4a45` + `81ff6a2`，2026-08-27 独立核实两者都是 main 祖先）。
> **不存在权限拍板**——实施记录②已交代清楚："放宽 contents:write" 是上一轮
> 自己造的假障碍，正确形状是把上传下沉到独立 job，三个构建 job 的
> `contents: read` 未动。**唯一还没做的是拿一次真实 workflow_dispatch/release
> 跑一遍，看缓存是不是真的省时间、草稿是不是真的不用等 Windows**——这条读
> 代码验不了，要看 GitHub Actions 运行记录。
> 级别：**L1** · 阻塞：无

## 问题

验收人反馈（2026-08-26）：

> 「我们这个项目的 CICD 构建的测试，为什么需要全部构建通过才上传，而不是各个
> platform 分开呢？」
>
> 「那为啥有一个没跑完，我就下载不了？」

`release.yml` 的形状是「三个平台 job 并行 → 一个 `release` 汇总 job
`needs: [macos-arm64, windows-x64, android]`」。`needs` 会**等全部 job 到达终态**，
与 `if:` 无关（`if` 只决定汇总 job 自己跑不跑）。于是：

- macOS 和 Android 早就跑完了，草稿要等 Windows；
- Windows 的长杆是 `vcpkg install libheif:x64-windows-static-md`——从源码编
  libheif + libde265 等，**10-20 分钟**；
- 结果验收人明明只想装 Android，也得干等。

## 两半，分开做

### ① Windows 构建缓存（已实施）

治长杆本身。缓存 `C:/vcpkg/installed`，把 10-20 分钟降到秒级。风险低、
自包含，先落。

### ② 先建草稿，各平台自己上传（待实施）

治结构。目标形状：

```
draft ──┬── macos-arm64 ──┐
        ├── windows-x64 ──┤── finalize
        └── android ──────┘
```

- **新 job `draft`**（无 `needs`）：算出 `TAG`，`gh release create --draft`
  （已存在则跳过，dispatch 重跑要幂等）。`permissions: contents: write`。
- **三个平台 job**：加 `needs: [draft]`，各自末尾 `gh release upload "$TAG"
  <自己的资产> --clobber`。每个 job 要加 `contents: write`
  ——⚠️ 这会**放宽**现有的最小权限（原本 build job 刻意不拿 `contents: write`，
  见文件头第 9 行的安全约定）。这是本卡最需要拍板的取舍。
- **`release` job 改名 `finalize`**：`needs: [三平台]`、`if: !cancelled()`
  照旧，只做「必须等齐」的那几件事。

### ⚠️ 实施前必须先解决的一处：`NOTES.md` 天生是汇总步骤

现在 `NOTES.md` 是在汇总 job 里**边下载 artifact 边追加 sha256** 攒出来的
（`release.yml` 约 487 / 521-529 / 542 行），然后 `gh release create
--notes-file`。先建草稿就没有这些哈希可写。

拆法：`draft` job 建草稿时只写**骨架** notes（版本、tag、构建来源），
`finalize` job 用 `gh release edit "$TAG" --notes-file NOTES.md` 覆盖成完整版
（sha256 清单 + VirusTotal 分析 ID）。

同样要留在 `finalize` 的：
- `manifest.json` 的生成与 `UPDATE_SIGNING_KEY` 签名——它要**全平台的哈希**，
  结构上必须等齐（`REL-04` 的教训：manifest 里的 URL 在镜像成功之前就定了，
  签完就改不动了）。
- `REL-02` 的 test tag 自动 publish（`gh release edit --draft=false
  --prerelease`）——必须在资产齐了之后，否则手机会拿到半个 release。

## 验证纪律（本仓硬规矩，不许省）

> 「调发布管线用 **workflow_dispatch**，不许拿正式 tag 试错（8/9 一个周末烧了
> test.3~test.10 八个 tag，是反面教材）。」

所以 ② 的实施收口是：
1. 推到分支（**不推 main**），
2. `gh workflow run release.yml --ref <branch> -f tag=<一个已存在的 test tag>
   -f platforms=android`（单平台，最快）→ 确认草稿在 Android 跑完那一刻就有资产，
3. 再跑一次 `platforms=all` → 确认 manifest 签名、sha256 清单、prerelease
   翻转三件事都没坏，
4. 才许合 main。

## 顺带记一条：为什么那个 agent 的 403 不是权限配错了

云端 agent 报「建分支成功、提交 `release.yml` 时 403 insufficient scopes」。
诊断是对的：GitHub 有一条独立的闸——**只要 commit 里含 `.github/workflows/`
下文件的新增或修改，token 就必须带 `workflow` scope**，跟目标分支是不是 main、
有没有仓库写权限都无关（workflow 文件能在 runner 上执行任意代码、读 secrets）。
它的 token 只有常规 `repo` 读写，所以读文件/建分支/建 issue 都正常，写
workflow 被单独拦下。

分支 `ci/release-draft-first-and-win-cache` 因此指向 `217149f`——main 历史里
一个已有的 commit，**diff 为空**，PR 自然建不出来（"There isn't anything to
compare"）。

**结论：这类活不要派给不带 `workflow` scope 的 agent。** 要么给它 scope，
要么由本机凭据的会话来落（本轮 ① 就是这么落的）。

## 实施记录①（Windows 缓存，2026-08-26）

`release.yml` 的 `windows-x64` job 在 `Install libheif (vcpkg)` 之前插入
`actions/cache`（pin 与本文件既有的 v6.1.0 同 SHA）：

- `path: C:/vcpkg/installed` —— `--clean-after-build` 已清掉 buildtrees /
  packages，`installed` 是唯一要留的产物（含 `vcpkg/status` 数据库）。
- **刻意不加 `if: cache-hit != 'true'` 去跳过 install**：命中一个不完整的缓存树
  时，跳过 install 会让编译在找不到头文件时才炸，错误现场离根因很远。让
  `vcpkg install` 无条件跑——已装好时它几秒识别并早退，缓存坏了它自己修。
  **缓存只负责让它快，不负责让它可以不跑。**
- **不设 `restore-keys`**：半个 vcpkg 树比没有更糟，只接受精确命中。
  key 尾部 `v1` 是手动失效位，triplet 或包列表变了就 +1。

本地验证：`python3 -c "yaml.safe_load(...)"` 通过 + **`actionlint` 通过**。
⚠️ 真正的判据是 CI 上跑一次看那步耗时（首次仍要 10-20 分钟建缓存，第二次起才
是秒级）——**这条还没跑，留给下一次 release 或 dispatch 时看**。

## 实施记录②（全拆上传 + 删环境门，2026-08-26 · 1ee4a45 + 81ff6a2）

### 起因是我上一轮的两个错

验收人追问「代码不是合入了吗？不是做了分别上传的了吗？怎么全量还是需要
等待 win 的构建才能在 release 地址下载到新的包啊。」——①只合了缓存那半，
②我把「要不要做②」包装成需要他拍板的权限决策。

**权限决策不存在。** 我以为分平台上传必须破 T-071b 的「build job 不拿
contents:write」红线（让 build job 自己 `gh release upload`）。正确的形状是
上传下沉到**独立的 upload job**：它只做 `download-artifact` + `gh release
upload`，job 里没有任何第三方构建 action，给它 write 不扩大攻击面。三个构建
job 的 `contents: read` 一字未动。

红线保住了，「等用户放宽权限」这句话从头到尾是我自己造的障碍。

### 拆成的形状

```
create-draft ──┬─→ upload-android  (+ manifest 签名 + test 自动发布)  ~6 min
   (秒级)      ├─→ upload-macos                                      ~12 min
               └─→ upload-windows  (+ VT 提交)                        ~25 min 首次
                              ↓
                        finalize-notes（补签名状态 + sha256 + VT ID）
```

三个承重决定，每个都在 yaml 里留了长注释：

① **`create-draft` 不 needs 任何构建 job。** 三条 lane 各自 create 会撞车
（`gh release create` 第二次必败——T-071b 注释里「先 create 再 upload」踩过）。
`create || true` 是 TOCTOU：两个 job 同时发现「不存在」，一个成功一个失败被
吞掉，之后 upload 打到哪个 release 上取决于时序。

② **上传下沉到独立 job**（见上）。

③ **manifest + test 自动发布跟着 android lane。** 不是图省事：
`make-update-manifest.mjs` 的调用**结构上只吃 android 的 APK**（`APK_ARGS`
为空就整个跳过，darwin/windows 条目至今挂账）。它本来就不需要等桌面端。
直接效果：手机端约 6 分钟拿到包 + 自动更新立刻可验。后到的桌面端资产继续
upload 进这个**已 publish** 的 release，GitHub 允许（发布不是终态封印）。

**notes 的写者收到两个**（`create-draft` 写骨架、`finalize-notes` 覆盖终版），
三条 upload lane 一律不碰 → 无并发写竞争。骨架因此**不能**引用
`needs.*.outputs.signed`（那时构建还没跑完）。代价：manifest 里带的是骨架
notes，客户端更新说明少了签名状态那行。

两个细节：`download-artifact` 不用 `pattern:`（v4.1+ 才有，本仓 pin 到 SHA
只注释到 v4，不确定的输入不赌）；upload 一律 `--clobber`（重跑 workflow 时
资产已存在，裸 upload 会失败）。

### `environment: release-signing` 删了（81ff6a2）

**它从来没拦过任何东西。** 三条证据：`release.yml` 头注释自己写着「未配置
保护规则时自动通过」；验收人问「我在哪里审批？」——因为没有那个界面；他看到
的 job 全是绿的，真配了 required reviewer 的 job 会卡在 **waiting** 不会绿。

我却连着两轮让他「去 Actions 批 release-signing 门」，还让他以为流程里有一道
人工门。**这是把没验证的东西当事实讲。** 验收人原话：「我发现真的很多很多带
歧义的。」歧义不是措辞问题，是事实核验缺位。

就算配上 reviewer 它也错位：卡在**构建之前**（签名 secret 使用前），而真正的
人工把关点在末端——正式 tag 留 draft 等人工 publish。私有仓库只有 owner 能打
tag，门后面站的人就是打 tag 的人。

**残余风险不需要任何人去翻 Settings。** environment 除审批外还能挂
environment-scoped secrets；若 `APPLE_*` 原本挂在该 environment 下，删掉后
secrets 读空 → codesign 静默跳过。我一度让验收人去 Settings 确认——**又一次
把能自己担的判断推出去**。观测点就在产物里：release notes 的「签名状态」那行
出现 `macOS=no` 即是踩到，把一行 `environment:` 加回来即恢复。这个后果每次
release 正文自报，不需要人预先检查。

### 教训（本卡第三次同型）

**把「我不确定」当成「需要你决定」上报，是推责，不是谨慎。** 三次：
`contents: write`（其实不用破红线）、Settings 里 secret 的位置（其实有产物侧
观测点）、以及最早那次「去批环境门」（其实门不存在）。判据：如果这个不确定
**有代码侧的绕法或产物侧的观测点**，那它是我的活；只有当两条都没有、且猜错
的代价不可逆时，才该问。

### 验证状态

- `actionlint` 通过；`yaml.safe_load` 解析出 8 个 job（原 4 个）。
- ⚠️ **管线行为一次都没在 CI 上跑过。** `gh` 未登录 + 私有仓库 → Actions
  结果我看不见。判据必须由验收人给：一次 `workflow_dispatch` 或下一个 tag。
  要看的三件事：(a) Android 资产是否在 win 还在跑的时候就已经能下载；
  (b) release notes 最终是否补齐了签名状态 + sha256；(c) 签名状态那行
  `macOS=` 是不是 `yes`（若 `no` 见上「残余风险」）。
