# Design tokens · 设计 token

Single source of truth for P-Pass visual design, extracted from the
Claude Design project ([P-Pass 设计项目], files `P-Pass Desktop.dc.html`
/ `P-Pass Mobile.dc.html`).

P-Pass 视觉设计的唯一事实来源，提取自 Claude Design 设计稿。

**The idea in one line**: warm paper, ink text, and *one* green that
means "photos are safe" — designed so a 60-year-old family member never
has to figure anything out.
一句话：暖纸底、墨黑字、一个只表示「安全」的绿——为 60 岁的家人设计。

| File | Consumed by |
|---|---|
| `tokens.json` | canonical definitions + design rules — **edit this first** |
| `tokens.css` | desktop shell (`apps/desktop`, imported by the Svelte app) |
| *(future)* `Tokens.kt` | Android app (M2 T-055) — generate from `tokens.json` |

Rules that are not colours (body ≥17px on phone, tap targets ≥56px,
≤40 words per screen, no jargon without a plain sentence, destructive
actions desktop-only…) live in `tokens.json → rules` and bind designers
and engineers equally.

非颜色规则（正文/点击区下限、每屏字数、术语带白话、危险操作只在桌面等）
在 `tokens.json → rules`，对设计与工程同等生效。

Keep `tokens.css` in sync by hand for now — the two files are small.
When Android lands, promote generation to a `just` recipe.
