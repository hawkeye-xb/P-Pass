# REL-02 更新通道分环境（test/stable）　级别 L2

## 背景（用户方向 2026-08-10）

自动更新机器已建好（UPD-01，双端指 `releases/latest/download/manifest.json`），
但用户要的流程是：**构建 → 验收 → 人工 publish 才推给家人**，同时
**开发设备要有一个"镜像环境"**——test 包出来就能自动更新，不用手动传包。
现状 draft 一刀切，两头都不满足。

## 方向

两条通道：

- **stable**（默认，家人设备）：`releases/latest/download/manifest.json`
  维持原样——GitHub 的 latest 只认「已发布的正式 release」，**人工
  publish 就是验收后的发布动作**，零新基建。
- **test**（开发/狗粮设备）：CI 出 test tag 包全绿后**自动 publish 为
  prerelease**（GitHub latest 天然忽略 prerelease，绝不会漏到 stable
  通道）；客户端 test 通道解析「最新 prerelease」的 manifest。

## 实现建议（可提替代方案，先写理由）

- release.yml：tag 含 `-test.` → `gh release edit --prerelease` 自动
  publish；正式 tag 保持 draft 等人工。
- Android：设置页加通道选项（默认 stable；test 通道走 GitHub API
  `releases?per_page=10` 取最新 prerelease 的 manifest 资产）。
- 桌面：tauri updater 需要静态 manifest URL——test 通道两个选法：
  ① 复用 T-062 的 update worker 占位（infra/workers/update），加
  `/manifest?channel=test` 代理 GitHub API（干净但多一块基建）；
  ② 桌面壳自己实现 test 通道检查（绕过 tauri updater 的静态 URL 限制，
  用现有 daemon_call 之外加一个壳内 fetch）。选哪个写清理由。
- 通道切换必须显式操作（设置页），默认永远 stable。

## 不准动

已打 tag；stable 通道的 URL 与语义；manifest 签名验证（两端现有验签
逻辑一根手指都不许松）。

## 可执行验收

1. 发一个 prerelease → test 通道设备检查到更新、stable 通道检查不到
   （两端各贴对照输出/截图）。
2. publish 一个正式 release → stable 通道检查到。
3. 篡改 manifest 签名 → 双端拒绝（既有测试不回归）。
4. 全量测试绿。

## 反证

test 通道包故意不 publish（留 draft）→ test 通道必须检查不到（贴输出）。

## 收尾

CI 绿；RELEASING.md 补通道说明（en+zh）；PROGRESS/NEXT 一行；卡移 done/。
