# P-Pass 站点（site/）

Landing + blog 静态站，Astro 构建，GitHub Pages 部署。

架构决策与内容管线见 `docs/product/2026-08-11-site-architecture.md`（语义基准，
不许偏离）。本目录只许动站点线相关文件；app 代码在 `apps/`、核心在 `crates/`。

## 本地开发

```bash
npm install
npm run dev      # http://localhost:4321
npm run build    # 产物 site/dist（构建前自动生成 tokens.css + 同步图标）
npm run preview  # 本地预览产物
```

## 设计令牌（tokens）

- 唯一数据源：`assets/design/tokens.json`（仓库根）。
- `src/styles/tokens.css` 由 `scripts/generate-tokens.mjs` 生成并**入库**，
  改了 tokens.json 后 `npm run tokens` 重新生成再提交；CI 跑
  `npm run tokens:check` 断言一致（防只改源忘生成）。
- 图标资产同理：`docs/design/2026-08-11-icon-v1/` 是源，`npm run icons`
  同步到 `public/icons/`（生成物入库，CI `icons:check` 断言一致）。

## 内容

- 文章放 `src/content/blog/*.md`，frontmatter：`title / date / tags / lang / draft`。
- `draft: true` 的文章构建时排除，适合待审草稿。
- 草稿完成即停等用户审，不许发布（SITE-02 规则）。

## 部署

`.github/workflows/site.yml`：paths 过滤 `site/**`，与主 CI 完全隔离；
构建 + 零第三方请求断言（allowlist 只放本站域 + github.com）+ Pages 部署。

自定义域 `p-pass.hawkeye-xb.com`（`public/CNAME` 入库；DNS 见 NEXT「等用户」）。
