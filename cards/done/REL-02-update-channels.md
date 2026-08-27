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

---

## 验收记录（2026-08-11 Salamira）

- release.yml：`contains(env.TAG, '-test.')` → `gh release edit --prerelease`
  （Compose notes 步骤把 TAG 写进 GITHUB_ENV，dispatch 与 tag 触发都覆盖）。
- Worker：infra/workers/update/src/index.ts（/manifest?channel=test|stable，
  300s Cache API 缓存，manifest 字节透传签名零改动，GH_TOKEN secret 可选）
  + wrangler.toml 占位（生产配置 ppf-ops，隔离方案 §2）；README 通道说明。
- Android：UpdateChannelStore（默认 stable）；fetchUpdate(channel)；
  channelManifestUrl 纯函数；设置页通道行 + 显式切换对话框；GitHub API
  直连解析（latestPrereleaseManifestUrl）删除。
- 桌面：设置页通道 select（localStorage）；checkTestChannel 壳内 fetch
  Worker + 弹窗 + openUrl 下载页；stable 路径原样。
- 测试：android 124/124（+3：stable URL 锁死反证/test Worker URL/默认
  stable）；vite build 绿。
- 用户指正（本卡关键修正）：GitHub 未认证 API 限流 60/h/IP——客户端不
  直连，解析挪 Cloudflare Worker（占位一直在，一个配置文件的事）。
- 挂验收人：①Worker 部署（wrangler deploy + DNS update.p-pass.hawkeye-xb.com，
  生产配置 ppf-ops）；②发 prerelease → test 检查到 / stable 检查不到
  （双端对照）；③publish 正式 release → stable 检查到；④反证：test tag
  留 draft → 双端静默；⑤篡改 manifest 签名 → 双端拒绝（既有测试不回归）。
