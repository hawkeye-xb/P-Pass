# REL-05 Release 的无 checkout upload/finalize job 未显式声明仓库，`gh release` 发布链断裂（L1）

> 🟠 状态：进行中 · 当前节点：`v0.5.0-test.3` 已建草稿并完成 Android 上传，但 macOS/Windows upload 与 finalize 仍缺仓库上下文；下一步：为所有无 checkout 的 `gh release` step 显式传 `GH_REPO`，以新 test tag 验证三端资产与正文 · 协同分支：`main`
> 级别：L1 · 阻塞：BUILD-03 必须修复 Windows lane，才能把同一新 test tag 作为完整 Release 验收。

## 问题

`release.yml` 的 create-draft、macOS upload、Windows upload 与 finalize 均执行 `gh release`。无 checkout 的 job 不能从 `.git` 推断仓库；必须显式传 `GH_REPO=${{ github.repository }}`，或 checkout。否则立即报：

```
failed to run git: fatal: not a git repository (or any of the parent directories): .git
```

`v0.5.0-test.2` 的 Release #46 在 create-draft 实证该错误；补 checkout 后，`v0.5.0-test.3` 的草稿和 Android prerelease 已生成，但 macOS/Windows upload 与 finalize 在无 checkout runner 上复现同一错误。

## 期望行为

每个 `gh release` 调用都拥有明确仓库上下文；对不存在的 tag 创建草稿，对重跑已有 Release 只刷新 notes。Android、macOS、Windows lane 可随后各自上传资产并补齐正文。

## 验收标准

- [ ] 新 test tag 的 create/upload/finalize job 均不再报 `not a git repository`，并创建对应 GitHub Release 草稿。
- [ ] Android upload 能读取该草稿、上传 APK 与 `manifest.json`，test Release 自动成为 prerelease。
- [ ] 反证：去掉无 checkout job 的 `GH_REPO` 后，`gh release upload/edit` 必须复现该失败；恢复后以新的 tag 通过。
- [ ] Release # 的完整结果为 green（Windows 缺口由 BUILD-03 同批解决）。

## 范围

- 只准动：`.github/workflows/release.yml` 的 `gh release` 调用上下文、对应测试/发布记录。
- 不准动：Release 构建 lane 的签名凭据门控、既有 Release/tag 的资产。

## 阻塞与依赖

BUILD-03：Windows lane 目前在 Android 专属源码上失败。两卡完成后才可将新的 test Release 视为清理历史 tag/release 的替代目标。

---

## 实施记录

- 2026-09-04：`v0.5.0-test.2` Release #46 的 create-draft 真实失败。日志确认 `contents: write` 已给出；根因仅是 job 未 checkout，不能以权限或 token 为由猜测。
