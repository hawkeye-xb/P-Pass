# 安全策略

[English](SECURITY.md)

## 报告漏洞

请**私下**报告漏洞，不要为此公开提 issue、发讨论或开 pull request。

1. 打开仓库的 [Security → Report a vulnerability](https://github.com/hawkeye-xb/P-Pass/security/advisories/new) 页面。
2. 写清问题、受影响的平台与版本、复现步骤。附概念验证更好，但不是必需。

报告只有维护者能看到。

## 之后的流程

- 我们会在 **7 天**内回复，确认已收到报告。
- 排查和修复期间，我们在同一份私密报告里同步进展。
- 修复发布后，我们会发布 [GitHub 安全公告](https://github.com/hawkeye-xb/P-Pass/security/advisories)，
  说明问题和已修复的版本。除非你要求不署名，公告中会致谢报告人。

## 受支持的版本

安全修复进入各平台（桌面端、Android、iOS）最新的正式版。测试版（版本号带
`-test` 后缀）和更早的版本不再修复，请升级到最新正式版。

## 范围

P-Pass 防什么、不防什么，见威胁模型 [docs/security/threat-model.md](docs/security/threat-model.md)。
