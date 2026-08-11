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

**⚠️ token 爆炸半径红线（BIZ-00 隔离原则）**：公开仓 secrets 里的 CF
token 必须是**窄权限**——只授 R2 指定 bucket 写 + 指定 Worker 部署，
不许账号级/Zone 级权限。生产部署级凭据永不进公开仓 secrets（公开仓
workflow 可被直推修改，一次误改即外流通道）。

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

---

## 验收记录（2026-08-12 Salamira）

**实现**：

① **pr.yml 拆分为按域独立 workflow**（pr.yml 删除）：
- `ci-rust.yml`（paths: crates/** Cargo.* config/** assets/i18n/**
  tools/arch-check.sh）——lint + test + arch-check + deny + actionlint。
- `ci-android.yml`（paths: apps/android/** assets/i18n/**）——单测 +
  assembleDebug + APK .so 断言。
- `ci-desktop.yml`（paths: apps/desktop/** assets/**）——src-tauri lib
  tests + vite build（pnpm，与 release.yml 一致）。
- 每个 workflow `concurrency: {group: <域>-${{github.ref}}, cancel-in-progress}`
- **依赖表（paths 对齐核心）**：crates/**（Rust 核心，金样本 snapshots.rs
  在 crates/proto，Android GoldenDriftTest 消费——android 域改动由
  ci-android 触发时比对，crates 改动由 ci-rust 自检，两侧全覆盖）；
  assets/i18n/** 同时进 rust（diag ALL 断言）+ android（捆绑副本对称
  测试）；assets/**（含 i18n）进 desktop（UI token 消费）。
- 纯 docs/.claude 提交不匹配任何 paths → 零 CI（验收 1）。

② **release.yml 平台选择**：workflow_dispatch 加 `platforms` 输入
（逗号组合 android/macos/windows，留空=all）；三平台 job 加 if 门控
（tag push 恒全量——发布完整性不许分块）；release 汇总 job 按 glob
实际产物收集（不存在的资产跳过）。

③ **Cloudflare 联动（secret 门控，token 未就位干净跳过）**：
- a. R2 发布镜像：release job 末尾新 step——资产镜像到 `ppf-dl`
  bucket `releases/<tag>/`（dl.p-pass.hawkeye-xb.com 已绑定）；update
  manifest 的 --asset-base 在有 CF token 时切镜像域（签名针对资产
  字节，换域名验签零变化——make-update-manifest.mjs 新增参数，本地
  双分支验证通过）；SHA256SUMS 一并镜像。**R2 基建已建**：ppf-dl
  bucket + custom domain dl.p-pass.hawkeye-xb.com。
- b. `ci-workers.yml`（paths: infra/workers/**）——临时 toml +
  wrangler@4 deploy（custom_domain 保真，不破坏现有绑定）；GH_TOKEN
  secret 提升 GitHub API 限额；CLOUDFLARE_API_TOKEN 未就位 → skip
  step + summary 标注。
- c. site 部署切 CF Pages：**不做**（SITE-01 已上 GH Pages，DNS 已改指
  hawkeye-xb.github.io，双发/切换是纯维护面增加零收益；理由入卡尾）。

④ **分层构建节奏**：
- 每推：受影响域快检+单测（①的拆分即实现）；纯 docs 零 CI。
- 每夜：e2e.yml 现有 nightly（30 3 * * *）——T-070 scenarios job
  **并轨进 e2e.yml**（同门禁：nightly/tag/labeled/dispatch；不再每推
  烧 release 构建）；全量 nextest 保持 nightly。
- 每 tag：release.yml 全平台发布级（现状保持）。
- CLAUDE.md 底线①口径更新：push 后盯**受影响域** CI；nightly 红次日
  第一优先修。
- 缓存治理：Windows 缓存 key 已是独立前缀 `win-x64-release-`
  （vcpkg 静态 libheif 不与 Linux/macOS 挤 10GB 上限），无需再改。

**验证**：
- actionlint 全部 8 个 workflow 零告警。
- make-update-manifest.mjs --asset-base 双分支（GitHub 默认 / R2
  镜像域）本地实测 url 正确。
- R2 ppf-dl bucket + custom domain 创建成功（wrangler 实测）。
- ⚠️ 本卡 commit 触发 CI 后需人工确认：①纯 docs 提交零 run
  ②只改 android 仅 ci-android 触发 ③dispatch platforms=android 只跑
  android+release ④连续 push 取消旧 run（验收 1/2/3/4 留 CI 实跑证据）。

**等用户**：GitHub 仓库 Settings → Secrets 添加 `CLOUDFLARE_API_TOKEN`
（+ 可选 `CLOUDFLARE_ACCOUNT_ID`、`GH_TOKEN`）后，R2 镜像 + workers
自动部署才启用（当前门控跳过路径已验证可跑）。
