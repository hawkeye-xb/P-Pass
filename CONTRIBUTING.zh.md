# 参与贡献 P-Pass

[English](CONTRIBUTING.md)

感谢你关注 P-Pass。本页说明每一份贡献都要满足的规则。

## 开始之前

- **报告问题、提功能建议**：用[问题模板](https://github.com/hawkeye-xb/P-Pass/issues/new/choose)开 issue。
  不确定是不是 bug，先到 [Discussions](https://github.com/hawkeye-xb/P-Pass/discussions/categories/q-a) 提问。
- **安全漏洞**：不要公开提 issue，按 [SECURITY.zh.md](SECURITY.zh.md) 私下报告。
- **代码改动**：一个改动一个分支、一个 pull request，并按
  [PR 模板](.github/PULL_REQUEST_TEMPLATE.md)填写。

## 贡献按什么许可证提交

提交贡献即表示你同意：你的贡献按 [AGPL-3.0](LICENSE) 授权，同时适用
[应用商店分发例外声明](APP_STORE_EXCEPTION.zh.md)。贡献的版权仍归你所有。
我们不要求签署贡献者许可协议（CLA）。

## 提交签名（DCO）

每个提交都要按 [Developer Certificate of Origin 1.1](https://developercertificate.org/)
签名。签名表示你确认这份改动是你写的，或者你有权按本项目的许可证提交它。

用 `git commit -s` 签名，它会在提交信息末尾加一行，且必须与提交的 author 一致：

```
Signed-off-by: Your Name <you@example.com>
```

PR 里如有提交缺少一致的签名，CI 检查 `CI DCO` 会失败。给分支上已有的提交补签：

```bash
git rebase --signoff origin/main
git push --force-with-lease
```

## 项目规则

- **文档双语**：面向用户与贡献者的文档以英文为主、配中文姊妹篇
  （`*.zh.md`）；短 README 可单文件双语分节。内部工程记录可中文优先；
  提交信息用英文。
- **接口 agent 优先**：所有功能必须可经 testclient CLI / daemon IPC
  无人化驱动与验证——GUI 只是这些接口上的皮肤。
- **架构门禁**：`iroh` 只准出现在 `transport`；平台 `#[cfg]` 只准出现在
  `platform`；由 `tools/arch-check.sh` 在 CI 强制。

## 行为准则

参与本项目的每个人都应遵守[行为准则](CODE_OF_CONDUCT.zh.md)。
