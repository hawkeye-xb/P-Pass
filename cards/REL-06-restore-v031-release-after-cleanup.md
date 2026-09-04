# REL-06 历史 test 清理误删 v0.3.1 Release，需从成功的 Release #24 artifacts 恢复（L3）

> 🟠 状态：进行中 · 当前节点：`v0.3.1` tag 仍在，但其 Draft Release 与九个原始分发资产已不在 Release 列表；下一步：从成功的 Release #24（commit `9c66c76`）保留 artifacts 重建同 tag 的 Draft Release 并逐一校验资产 · 协同分支：`main`
> 级别：L3 · 阻塞：无

## 问题

清理历史 test Release/tag 时，旧 Release 被转为 untagged 后统一删除；`v0.3.1`
Release 也被误纳入删除范围。远端 `v0.3.1` tag 仍存在，但 Releases 页面只剩
`v0.5.0-test.4` 与 `dogfood`，不符合保留正式版的决定。

原始 Release #24 成功（2026-08-09，commit `9c66c76`），其 Android、macOS、
Windows 与 Windows installer artifacts 仍可从 Actions 获取。

## 期望行为

恢复绑定既有 `v0.3.1` tag 的 Draft Release，保留其原本“未发布 stable”的语义，并
恢复原始九个可分发资产；不重建为当前 0.5.0 代码，不把 0.3.1 误发布为 latest。

## 验收标准

- [ ] GitHub Releases 页面同时列出 `v0.5.0-test.4`、`v0.3.1` Draft 与 `dogfood`。
- [ ] `v0.3.1` Release 绑定原 tag `9c66c76`，保留 Draft；不设 prerelease/不发布。
- [ ] 原 Actions #24 的 9 个资产全部恢复：Android APK、macOS DMG/zip/SUMS、Windows daemon/testclient/SUMS/build info/installer。
- [ ] 逐项下载或页面核对文件名与原 Actions #24 artifact 清单一致；`v0.5.0-test.4` 和 `dogfood` 不被修改。

## 范围

- 只准动：GitHub `v0.3.1` Release 记录及其从 Release #24 恢复的资产、相关卡片/队列/进度文档。
- 不准动：`v0.3.1` tag、`v0.5.0-test.4`、`dogfood`、任何源代码与签名凭据。

## 阻塞与依赖

无。

---

## 实施记录

- 2026-09-04：确认远端保留 `v0.3.1 -> 9c66c76` 与 `dogfood`、`v0.5.0-test.4`。Release #24 为 Success，四个 Actions artifact 仍在，含恢复所需九个资产。
