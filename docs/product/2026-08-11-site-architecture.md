# P-Pass 站点架构（landing + blog）——设计定稿，agent 执行

> 用户方向（2026-08-11）：不急着改 README，先搭更高层面的对外阵地——
> landing page + blog，把产品设计、想法、开发过程持续发出去。
> 验收人定架构，实施 agent 跑（SITE-01/SITE-02 卡）。

## 架构决策（验收人裁决，用户可否）

| 决策 | 选择 | 理由 |
|---|---|---|
| 形态 | **纯静态站**，零后端零收集 | 与产品的隐私立场自洽——做隐私备份的官网不该有 tracker；托管免费 |
| 生成器 | **Astro** | landing 需要设计自由度（组件化），blog 就是 Markdown 目录；agent 生态熟悉度最高，出问题好修 |
| 位置 | 主仓 `site/` 目录 | 推送/记录/巡检一套流程管到底；文章和产品档案同仓引用方便 |
| 部署 | GitHub Actions（paths 过滤 `site/**`）→ GitHub Pages | 零新基建；不触发主 CI |
| 域名 | `p-pass.hawkeye-xb.com` | zone 已在（relay-*/update. 同族）；CNAME → GH Pages |
| 视觉 | 直接消费 `assets/design/tokens.json` 构建期生成 CSS 变量 | 暖纸/墨/安全绿 + 屋脊兽资产已齐，站点不许发明新色 |
| 语言 | 结构双语预留，**内容 zh 先行**，en 随开源节奏补 | 精力现实；结构上 `/en/` 留位不返工 |

## 内容架构

```
site/
  src/pages/index.astro        # landing：一句话+屋脊兽+下载(指 releases latest)+三条卖点
  src/pages/blog/…             # 列表+文章页
  src/content/blog/*.md        # 文章（frontmatter: title/date/tags/lang）
  src/styles/tokens.css        # 构建期从 tokens.json 生成
```

**Landing 只说三件事**（对齐产品定位档案）：①照片回家——备份到自己家的
电脑，不经过任何人的云；②为 60 岁的家人设计——扫码即用，都存好了；
③开源、端到端加密、按类型逐步扩展。CTA = 下载（GitHub Releases）。

## Blog 素材管线（长期机制）

- **素材源现成**：`docs/product/*` 每一篇定案 = 一篇文章的骨架；
  `docs/design/2026-08-11-icon-v1/drafts-gallery.html` 九轮过程 =
  天然的设计复盘文；PROGRESS 里的事故记录（daemon 误接管、幽灵照片）=
  最好的工程文。
- **节奏**：每个里程碑收口 → agent 从档案提炼草稿 →（用户审 10 分钟）→
  merge 即发布。审稿是唯一人工环节。
- **选题库（素材就绪即可写）**：《一个 flake 的取证学——从 300 秒幽灵超时到上游
  issue [n0-computer/iroh#4468](https://github.com/n0-computer/iroh/issues/4468)》
  （素材：FIX-SC2 卡全程 + 取证桩设计 + 死锁栈 + issue 正文——完整的
  debugging 叙事弧，含"取证桩把 rerun 碰运气变成每次失败都在积累证据"）；
  《幽灵照片》（SYNC-01）；《备份工具怎么防止把自己备份进死循环》（RET-01 钉子）。
- 首批三篇（SITE-02）：《为什么给家人做一个照片备份》（定位+裁决故事）、
  《一只屋脊兽的诞生》（图标九轮，配过程图）、《从 3 秒轮询到 36 毫秒》
  （IPC-02 重构记）。

## 明确不做

评论系统、分析统计、邮件订阅、CMS——全是维护负担，RSS 就够。
