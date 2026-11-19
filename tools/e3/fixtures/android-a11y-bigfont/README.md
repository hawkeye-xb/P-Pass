# android/a11y-bigfont 判定回放（#1801）

证据树取自 #1801 第四轮真机 1.5x 大字体 dump（本分支 ci/1801-1792-talkback 的 debug 包，
三星 SM-S928N @450dpi，Android 16），只用于离线回放判定。真机原始输出（png / logcat / 逐页 xml
与 manual-bigfont.md 的本轮人工判定）在本机 `.evidence/1801/round4/`，不进 git。

判定要点（判据全文见 a11y-bigfont.sh 文件头）：

- 触控目标 48dp **硬判红**；显式白名单只有一条：范围页时间筛选 Chip（#1882 已知项，1.5x 选中枚
  触控区 32dp，另卡修）——被滚动视口裁剪的行只记 WARN（dump 里的可见高度不等于真实触控区）。
- 「最大字体无关键截断」归人工判定：`pass/` 里的 `manual-bigfont.md` 是对这套截图的人工结论
  （截断 = 信息丢失：Ellipsis 省略号或裁到读不全；折行错位不是截断，另记观察项）。

每个反例只让一条判据出错：

- `pass/`：zh-CN 与 en-US 各一套设置页（顶部 + 滚动后）+ 范围页 + 看图页 + 人工判定行。
- `fail-label-missing/`：两份 settings dump 里「从文件选择」都抹掉——关键文本判据红。
  （两份都抹是因为判据跨屏合并看文本，只抹一份还会被另一屏救回来。）
- `fail-crash/`：crash buffer 三行 FATAL——crash 判据红（语种证据齐全，只红这一条；
  crash 检查在语种循环之外，这是 2026-11-19 修过的 bug：一度放循环里，纯 crash 反例会漏判）。
- `fail-no-locale-evidence/`：只有空 crash.txt、没有任何语种目录——
  「没有任何语种证据目录」闸红（没有页面证据不许判过）。
- `fail-touchtarget-unknown/`：把被裁剪的「通知」行挪到屏幕中部并压到 36px——
  不贴视口边缘（裁剪豁免不认）、不是 Chip（白名单不认），48dp 硬判红必须抓到它。
- `fail-manual-truncation/`：manual-bigfont.md 写「判定：有关键截断」——人工判定门红。
