# REL-05 Release create-draft 未 checkout，`gh release` 无仓库上下文导致发布链全断（L1）

> 🟠 状态：进行中 · 当前节点：`v0.5.0-test.2` Release #46 已以该错误失败；下一步：为 create-draft 增加 checkout 并以新 test tag 验证草稿、资产上传与 prerelease 发布 · 协同分支：`main`
> 级别：L1 · 阻塞：BUILD-03 必须修复 Windows lane，才能把同一新 test tag 作为完整 Release 验收。

## 问题

`release.yml` 的 `create-draft` job 直接执行 `gh release view/create`，但没有 checkout。GitHub Actions runner 的工作目录因此没有 `.git`，`gh` 无法推断仓库，立即报：

```
failed to run git: fatal: not a git repository (or any of the parent directories): .git
```

`v0.5.0-test.2` 的 Release #46 已实证该错误。Android、macOS 构建虽然完成，草稿未建使 Android/macOS 上传、finalize 都级联失败，测试更新 manifest 也没有产生。

## 期望行为

create-draft 在不等待构建 lane 的前提下，拥有 `gh release` 所需的仓库上下文；对不存在的 tag 创建草稿，对重跑已有 Release 只刷新 notes。Android、macOS、Windows lane 可随后各自上传资产。

## 验收标准

- [ ] 新 test tag 的 `create-draft` 不再报 `not a git repository`，并创建对应 GitHub Release 草稿。
- [ ] Android upload 能读取该草稿、上传 APK 与 `manifest.json`，test Release 自动成为 prerelease。
- [ ] 反证：去掉 create-draft 的 checkout 后，针对不存在 tag 的 `gh release create` 必须复现该失败；恢复后以新的 tag 通过。
- [ ] Release # 的完整结果为 green（Windows 缺口由 BUILD-03 同批解决）。

## 范围

- 只准动：`.github/workflows/release.yml` 的 create-draft job、对应测试/发布记录。
- 不准动：Release 构建 lane 的签名凭据门控、既有 Release/tag 的资产。

## 阻塞与依赖

BUILD-03：Windows lane 目前在 Android 专属源码上失败。两卡完成后才可将新的 test Release 视为清理历史 tag/release 的替代目标。

---

## 实施记录

- 2026-09-04：`v0.5.0-test.2` Release #46 的 create-draft 真实失败。日志确认 `contents: write` 已给出；根因仅是 job 未 checkout，不能以权限或 token 为由猜测。
