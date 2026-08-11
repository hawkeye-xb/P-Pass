# SITE-01 站点脚手架（landing + blog）　级别 L2

## 语义基准

docs/product/2026-08-11-site-architecture.md——架构决策照单全收，不许
换生成器/加后端/引 tracker。

## 交付

1. `site/` Astro 脚手架：landing（index）+ blog（列表/文章/RSS）；
   `src/styles/tokens.css` 由 assets/design/tokens.json 构建期生成
   （脚本幂等）；图标资产从 docs/design/2026-08-11-icon-v1/ 引用。
2. landing v1 内容照架构档案「只说三件事」，文案从产品定位档案改写，
   不许自创卖点；下载按钮指 GitHub Releases latest。
3. `.github/workflows/site.yml`：paths 过滤 `site/**`，构建推 GitHub
   Pages；与主 CI 完全隔离。
4. 自定义域 `p-pass.hawkeye-xb.com`（CNAME 文件入库；DNS 记录若无权限
   操作则在 NEXT「等用户」写清要加的记录值）。
5. 移动端适配 + 暗色跟随（tokens 双色已有）。

## 可执行验收

1. Pages 上线可访问，landing/blog/RSS 三路由 200（贴 URL）。
2. Lighthouse 性能+可访问性 ≥90（纯静态应轻松，贴分数）。
3. grep 站点产物无任何第三方请求域（CSP 自证零 tracker）。
4. tokens.css 与 tokens.json 数值一致（脚本断言）。

## 收尾
文档三件套；卡移 done/。
