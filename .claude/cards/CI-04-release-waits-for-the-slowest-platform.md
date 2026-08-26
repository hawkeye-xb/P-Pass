# CI-04 三平台并行跑完才建草稿——一个没跑完就一个都下载不了　级别 L1

> 🟡 状态：**Windows 缓存那一半已实施**（见「实施记录①」）；
> **先建草稿那一半待实施 + 必须 workflow_dispatch 验证过才许合 main**
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
