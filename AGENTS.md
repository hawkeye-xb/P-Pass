# P-Pass 执行 agent 工作规范

唯一必读。一页以内，读完就开工。

## 流程（就这一条循环）

```
issue（为什么做）→ 分支 → PR（怎么做的）→ 验收人 review + CI → squash 合入
```

- **执行 session**（验收人给了 issue 号）：`git fetch origin --prune`，确认不落后
  远端，读该 issue 即全部任务上下文。issue 里 `requires:` 指到的文档才读，
  否则不读。**没有 QUEUE/PROGRESS/NEXT/cards 需要读——它们已全部退役。**
- **状态对齐**（问进度/下一个做什么）：看 GitHub Issues + milestone，
  不在仓里读任何状态文件。

## 红线（违反=事故）

1. **issue 外的活不做。** 发现新问题开新 issue 挂号，继续当前活，不顺手修。
2. **范围即边界。** 只动 issue「范围」段列出的文件；确需扩大时先改 issue 再改
   代码，同批 push。产品红线：只做图片，不做文件备份/同步。
3. **不捏造。** 报绿必须附命令 + 真实输出；故障/安全类判据必须带反证
   （去掉故障条件必须变红）。"CI 绿"不等于验收。
4. **凭据只在 GitHub Secrets。** 不进代码、issue、文档；本机路径/设备状态
   只写 `local-state.md`（不进 git）。
5. **红测不进 main。** 一 issue 一分支本身就是隔离：红测停下时把红留在自己
   分支上、别开 PR（或标 draft），并在 issue 里写明停在哪、剩什么。

## 验收证据分级

- **E1** 编译 + `just ci` 硬门——永远可信
- **E2** 针对当前架构 case matrix 写的 contract 测试——可信
- **E3** 真机/真环境实证输出（日志/截图/测试计数）——L3 必需
- **E4** legacy 测试——仅参考，不许单独作为验收通过依据

报绿时说明每条结论出自哪一级。

## 交付

- **一 issue 一分支，走 PR 合入，不直推 main。**
  `git fetch origin && git switch -c <type>/<issue号>-<slug> origin/main`
  （type ∈ feat/fix/docs/test/ci）。
- **分支上快验，PR 上全验。** 推分支不触发 CI（四条 lane 的 `push` 限定
  `branches: [main]`）：纯文档 `just ci-docs`，动了代码 `just ci`。
  开 PR 才跑受影响域 lane。
- PR 开出后盯受影响域 CI 到结论，红了在同一分支上修，不留红 PR。
- **带 GitHub MCP 的会话**（协作者账号 `690591397`）：自己把 PR 全程做完——
  推分支、开 PR（描述里逐项回接收尾检查）、盯 lane、squash 合并。
  未绑定该账号的 agent：推完分支停下，汇报分支名 + 自验结果 + 预填开 PR
  链接，开 PR 与合并由验收人在网页完成。
- PR 合并后清本地：`just cleanup-local`（默认预览，删除要 `--apply`）。
  本仓走 squash 合并，判断分支能否删看上游 `: gone]`，用 `-D` 不用 `-d`。
- tag 只给真发版本。调管线不发版走 Actions → Release → Run workflow。
- 构建产物、日志不进 main。

## 机器兜底（`just ci` 会挡，不用背）

- iroh 只在 `crates/transport/`。
- 平台分叉只许在 `crates/platform/`：自己写 `#[cfg(unix)]` / `#[cfg(windows)]`
  这类按操作系统分叉的代码，出了 platform crate 门禁必挡——含 `cfg_attr`
  与 `cfg!` 形态，含 unix/linux/macos/target_family/target_env 全轴；扫
  `crates/` 与 `apps/`，不扫 `tools/`。判据（QA-09 #186）：框架抹平差异、
  暴露统一 API 的不算分叉；我们自写「A 平台这样、B 平台那样」才算。两个
  登记例外：`windows_subsystem` 链接器指令按**属性名**豁免；#211 挂号的
  存量（迁移中，arch-check 脚本 carve-out 销号后即删）。桌面壳不整体豁免，
  它的自写分叉同属 #211 迁移对象。
- 工具链版本唯一真相：`rust-toolchain.toml`（Rust）、CI `java-version`（JDK）。

## 索引（需要时才打开）

| 你要做什么 | 去哪 |
|---|---|
| 开 issue | GitHub issue 模板「任务卡」 |
| 本地跑测试 | `just --list` |
| 发版、签名、版本纪律 | `docs/RELEASING.md` |
| 验收协议细则（L 分级由来、抽检法） | `docs/AGENT_PROTOCOL.md` |
| 历史事故与教训（出同类事故才翻） | `docs/lessons/` |
| 历史账本与旧卡（档案馆，非常驻阅读） | `docs/PROGRESS.md`、`cards/done/` |
