# android/a11y-bigfont 判定回放（#1801）

证据树取自 #1801 第四轮真机 1.5x 大字体 dump（本分支 ci/1801-1792-talkback 的 debug 包，
三星 SM-S928N @450dpi，Android 16），只用于离线回放判定。真机原始输出（png / logcat / 逐页 xml
与 manual-bigfont.md 的本轮人工判定）在本机 `.evidence/1801/round4/`，不进 git。

判定要点（判据全文见 a11y-bigfont.sh 文件头）：

- 触控目标 48dp **硬判红**，没有白名单：范围页时间筛选 Chip 在大字体下也必须 ≥48dp
  （#1882 已修：筛选条抬到网格之上并裁住网格触控框）。被滚动视口裁剪的行只记 WARN
  （dump 里的可见高度不等于真实触控区）。
- 「最大字体无关键截断」归人工判定：`pass/` 里的 `manual-bigfont.md` 是对这套截图的人工结论
  （截断 = 信息丢失：Ellipsis 省略号或裁到读不全；折行错位不是截断，另记观察项）。
- 系统字号与动画缩放按语种回读（`scales.txt`）：`font_scale` 必须回读到 1.5、三个动画缩放必须
  回读到 0——`settings put` 静默失败（写入没生效、证据其实是 1.0x）时判红，不靠 act 单方面假定。

每个反例只让一条判据出错：

- `pass/`：zh-CN 一套设置页（顶部 + 滚动后）+ 范围页 + 看图页 + 人工判定行 + `scales.txt`
  （回读字号 1.5 / 三个动画缩放 0）。
- `fail-label-missing/`：两份 settings dump 里「从文件选择」都抹掉——关键文本判据红。
  （两份都抹是因为判据跨屏合并看文本，只抹一份还会被另一屏救回来。）
- `fail-crash/`：crash buffer 三行 FATAL——crash 判据红（语种证据齐全，只红这一条；
  crash 检查在语种循环之外，这是 2026-11-19 修过的 bug：一度放循环里，纯 crash 反例会漏判）。
- `fail-no-locale-evidence/`：只有空 crash.txt、没有任何语种目录——
  「没有任何语种证据目录」闸红（没有页面证据不许判过）。
- `fail-touchtarget-unknown/`：把被裁剪的「通知」行挪到屏幕中部并压到 36px——
  不贴视口边缘（裁剪豁免不认），48dp 硬判红必须抓到它。
- `fail-truncation-en15/`：en-US 1.5x 一套，人工判定写「有关键截断」（范围页「Include older
  photos」Chip 视觉截断成「Incl」，已开 #1886）——人工判定门红。
- `fail-scale-readback/`：`pass/` 基础上把 zh-CN 的 `scales.txt` 回读写回 `font_scale=1.0`——
  系统字号回读断言红（put 静默失败当场抓出来，#1888）。
