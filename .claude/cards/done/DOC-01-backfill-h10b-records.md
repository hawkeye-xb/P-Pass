# DOC-01 补记 h10b-T1~T7 批次文档　级别 L0

## blocker

2026-08-08/09 的 13 个 commit（h10b QR 密度/dmg 布局/T1 版本号/T3 token/
T4 配对状态机/T5 审计流/T6 相册范围/T7 Windows NSIS + 0.3.1 bump）在
PROGRESS/ROADMAP/NEXT 全部零记录——验收人只能从 git log 反向考古。
「每批交付必更文档」是仓库根 CLAUDE.md 三底线之一，本卡补欠账。

## 修法

- PROGRESS.md：h10b 每卡一行（日期/commit/状态/摘要），按 git log 事实写，
  **不许脑补验收结论**——没做过真机验收的一律写「待验收」。
- ROADMAP.md：H-10b 相关行状态更新到当前事实（0.3.1 已出、Windows GUI
  安装包已进管线等）。
- NEXT.md：「当前队列」指向 .claude/cards/，过时的「等 test.5 实测」类
  段落按现状改写。

## 可执行验收

1. h10b 13 个 commit 每个都能在 PROGRESS 里找到归属行。
2. 文档里的每个论断都能指到 commit/run/测试输出；验收状态如实标注。
3. grep 复查：PROGRESS/NEXT 无「已通过真机验收」类无证据表述。

## 收尾

直推 main；卡移 done/。
