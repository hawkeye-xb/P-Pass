# CI-01 流水线分块重构　级别 L2（用户点名 2026-08-11）

## 现状病灶（验收人已核）

1. pr.yml 对 main 每次 push **无路径过滤全量跑四 job**（含 release 构建
   的 scenarios，40min 上限）——本项目文档/卡片提交密集，大量纯浪费；
2. 无 concurrency 取消——连续推送时旧 run 白跑到底；
3. release.yml 无平台选择——只出 Android 包也要等 Windows vcpkg。

## 修法

### ① pr.yml 拆分为按域触发的独立 workflow

- `ci-rust.yml`：paths `crates/** Cargo.* config/** assets/i18n/**
  tools/arch-check.sh` → lint+test + scenarios（scenarios 保留，它抓过
  FIX-SC1）；
- `ci-android.yml`：paths `apps/android/** assets/i18n/**`；
- `ci-desktop.yml`：paths `apps/desktop/** assets/**`；
- PR 事件保留同样触发；**纯 docs/.claude 提交 → 零 CI**。
- 每个 workflow 加 `concurrency: { group: <name>-${{ github.ref }},
  cancel-in-progress: true }`。
- ⚠️ paths 列表与实际依赖对齐是本卡验收核心——漏一个共享路径（如
  proto 金样本、i18n 字典）= 该域改坏了 CI 不知道。先画依赖表再写 paths，
  依赖表进 commit message。

### ② release.yml 平台选择

workflow_dispatch inputs 加 `platforms`（默认 all，可 `android` /
`macos` / `windows` 逗号组合）；三个平台 job 加 `if` 门控；release 汇总
job 按实际产物收集。**tag push 永远全量**（发布完整性不许分块）。

### ③ Cloudflare 联动（前置：用户在 GitHub 加 CLOUDFLARE_API_TOKEN）

a. **R2 发布镜像**：release.yml 出包后新增 job——资产上传 R2 bucket
   （`ppf-dl`），绑定 `dl.p-pass.hawkeye-xb.com`；update Worker 的
   manifest URL 改指镜像域（国内下载可达性）。SHA256SUMS 一并镜像，
   验签语义零变化。
b. **workers 自动部署**：`ci-workers.yml`，paths `infra/workers/**` →
   wrangler deploy（account/route 等生产值经 secret/vars 注入，敏感值
   不入库——沿用 ppf-ops 镜像惯例）。
c. **site 部署切 CF Pages**（可选项，SITE-01 已上 GH Pages 则做成双发
   或切换，写理由）。
token 未就位时：a/b/c 全部做成「secret 存在才启用」的门控 step，
缺 secret 干净跳过并在 summary 标注（沿用 APPLE_CERT 门控先例）。

### ④ 分层构建节奏（业内标准三层，本卡一并落）

- **每推**：受影响域的快检+单测（①的拆分即实现）；纯 docs/.claude 零 CI。
- **每夜**：全量 nextest + scenarios（scenarios 从每推挪到 nightly +
  tag 前门禁——它抓真 bug 但不该每推都烧 release 构建；e2e.yml 已有
  nightly 先例，并轨即可）。
- **每 tag**：全平台发布级（现状保持）。
- 底线①口径随之更新进 CLAUDE.md：push 后盯**受影响域** CI 绿；nightly
  红次日第一优先修。
- 缓存策略顺手治理：四平台缓存 key 加边界（10GB 仓上限 LRU 挤兑是
  Windows vcpkg 反复重编的根因），必要时 Windows 缓存单独 key 前缀。

## 不准动

e2e.yml（nightly+tag 门禁语义）；artifacts.yml；release tag 全量语义；
任何测试内容本身。

## 可执行验收

1. 纯 docs 提交 → Actions 零新 run（贴 run 列表截图）。
2. 只改 apps/android → 仅 ci-android 触发（贴对照）。
3. dispatch platforms=android → 只跑 android+release 两 job，产物只有
   APK 相关（贴 run）。
4. 连续两次 push → 第一次 run 被 cancel（贴状态）。
5. 依赖表 vs paths 对照进 commit message；金样本/i18n 改动能触发对应
   全部相关域（反证：故意漏掉 i18n 路径 → android 域改字典不触发 =
   验收失败演示后补上）。
6. CF 三项：token 在位则各贴一次成功 run；不在位则贴门控跳过证据 +
   NEXT「等用户」记 token 事项。

## 收尾
文档三件套（RELEASING.md 补分块说明）；卡移 done/。
