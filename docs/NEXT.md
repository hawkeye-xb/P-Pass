# NEXT — 当前状态与下一步（2026-08-12，链 2 批次完成）

> 交接件，随每次收口更新。历史结论已并入 ROADMAP/PROGRESS。

## 〇、2026-08-12 链 2 批次（Salamira）：RET-01 → SENT-01 → DOG-02b → DESK-04 → CI-01 全部完成

**五卡全部推 main**（语义基准 docs/product/2026-08-11-chain2-decisions.md
①③④⑤⑥；ROADMAP「链 2 取回/哨兵批次」小节）：

| 卡 | commit | 验证 | 真机挂账 |
|----|--------|------|---------|
| RET-01 取回=使用动作 | 4a92aae | android 140/140 | 保存到相册可见+时间元数据；打开面板+临时目录零残留；断网人话错误 |
| SENT-01 手机哨兵 | 29af0ff | android 150/150 | mock 全失败→通知一次不重复；恢复可达清零 |
| DOG-02b 白名单提醒 | a0792fe | android 161/161 | mock 条件满足→通知+点开引导；加白后不再通知 |
| DESK-04 向导对齐 | 9072735 | vite build 绿 | 三步截图对照；扫码→确认列表即时出现 |
| CI-01 流水线分块 | 5b8cb88 | actionlint 8/8 | CI 实跑验收（纯 docs 零 run/单域触发/platforms 门控/取消旧 run）留推后确认 |

**⏳ 等用户过目（issue 草稿，先不发）**：
`docs/iroh-blobs-load-deadlock-issue-draft.md` —— iroh-blobs 0.103
`FsStore::load` 失败路径自锁死锁的英文 issue 草稿（最小复现 + sample
栈摘录 + 根因分析 + 修复建议）。**用户过目后决定是否代发到
n0-computer/iroh**（FIX-SC2 卡尾报告同源，未发过）。

**等用户（CI-01 CF 联动激活）**：GitHub 仓库 Settings → Secrets and
variables → Actions 添加 `CLOUDFLARE_API_TOKEN`（+ 可选
`CLOUDFLARE_ACCOUNT_ID`、`GH_TOKEN`）——R2 发布镜像
（dl.p-pass.hawkeye-xb.com/releases/<tag>/）与 workers 自动部署
（ci-workers.yml）当前为门控跳过态，token 到位即自动启用。
R2 基建已建好：bucket `ppf-dl` + custom domain `dl.p-pass.hawkeye-xb.com`。

**队列剩余**：NAME-01（L0 排队尾可砍）；恢复向导（后置）。SITE-02
三篇博文草稿在 site/site-02 分支待用户审稿（**维持 draft 不动**，
审后去 draft 发布——用户 2026-08-12 指令）。

## 历史真机挂账汇总（跨多轮未闭环，照单核对）

- **PRES-01**：真机锁屏 10 分钟活动流不刷屏 + 桌面「3 分钟前在线」观感。
- **IPC-02**：扫码 → QR 弹窗即时关/授权列表即时出（时序日志）；断
  daemon → 壳自动重连重订阅状态恢复；反证：订阅失效 → 兜底轮询仍工作。
- **SYNC-01**：三星真机对账后拉 timeline 被删照片消失（exist-check
  回落链）。
- **DESK-03**：真窗口 500 张滚动流畅度、大图/Finder 揭示走查。
- **MOB-03/ICON-01b 模拟器截图**：⏳ 受阻挂账——本机 VM 无嵌套虚拟化
  （HVF 不可用），模拟器 TCG 纯软件渲染 App 启动即 ANR；替代路径：
  三星真机卸载重装=全新零权限态，或换有 HVF 的机器。挂验收人裁决。
- **v0.3.3-test.1 真机更新走查**：test 通道收包 + 安装（REL-02 链）。
- **0.3.0 六项验收**（拖多轮）：main branch protection（require PR +
  approval，禁直推——第三次违纪后硬性止血）+ 下载 0.3.0-test.2 APK
  到 ~/Downloads（三星在线即跑）。

## 〇、2026-08-11 FIX-SC2 完成轮（Salamira）：blobs_resume stall 根因锁定 + 修复

（历史，并入上文 issue 草稿）FIX-SC2 第 2/3 步完成——blobs_resume
300s 超时 flake 根治：根因 = test harness 竞态（in-process abort 后
redb 锁在独立 runtime 的 store actor 手里异步释放）+ 放大 =
iroh-blobs 0.103 上游 bug（Actor::new 错误路径 drop 捕获的 RtWrapper
→ block_in_place(drop(Runtime)) 自锁，错误被吞 → 挂起非 panic）。
修复 = 文件锁释放轮询替代固定 100ms 睡眠。验证 40/40 压力循环全绿。
**上游报告已存档为英文 issue 草稿（见上，等用户过目）**。

## 〇、2026-08-11 SITE-01 轮（Salamira）：站点脚手架（landing + blog）

**SITE-01 已完成并推 main**：Astro 5 纯静态站落地 `site/`——landing
只说三件事（照片回家 / 为 60 岁的家人设计 / 开源·端到端加密）+ 碳纹
图标 + 下载 CTA（指 Releases latest）；blog 列表/文章/RSS/404；tokens.css
由 assets/design/tokens.json 构建期生成（脚本幂等 + CI 断言一致）；
零 tracker（CI 断言产物无第三方请求域）。site.yml（paths 过滤
`site/**`）与主 CI 隔离，推 GH Pages。CNAME 入库。

**等用户 / 验收人**：
1. Pages 部署后 `https://p-pass.hawkeye-xb.com` landing/blog/RSS 三路由
   200 + Lighthouse ≥90（本 VM 无外网出站，部署/测分走验收人）。
2. **DNS 待改**：CF zone `hawkeye-xb.com`（zone id
   65dec62bc61b00e5d22fedc40b774bdc）里 `p-pass.hawkeye-xb.com` 的
   CNAME 目前指向旧占位 `p-pass-landing.pages.dev`——**需改为
   `hawkeye-xb.github.io`**（GH Pages）。
3. SITE-02 三篇博文草稿在 site/site-02 分支待审（维持 draft 不动）。
