# android/a11y-bigfont 判定回放（#1801）

证据树取自 #1801 第三轮真机 1.5x 大字体 dump（origin/main b249aaf3 的 debug 包，三星 SM-S928N @450dpi），
只用于离线回放判定，不是新的真机证据。1.5x 下已知未修的观察项（备份范围折行错位、选中 Chip 32dp）
在该判据里是 WARN 量表记录，所以 `pass/` 里带着它们照样判过——这是有意的（见 a11y-bigfont.sh 文件头）。

每个反例只让一条判据出错：

- `pass/`：zh-CN（zh15_settings_tab + zh15_settings_bottom2 + zh15_scope_open）与 en-US。
  en-US 的 `settings-scrolled.xml` 是构造的——EN 1.5x 没截滚动后的设置页，用 1.08x 的
  `en108_settings.xml` 顶「五条关键文本都在」这条判据的回放（判据按文本合并两屏看，不判 dpi）。
- `fail-label-missing/`：两份 settings dump 里「从文件选择」都抹掉——关键文本判据红。
  （两份都抹是因为判据跨屏合并看文本，只抹一份还会被另一屏救回来。）
- `fail-crash/`：crash buffer 三行 FATAL——crash 判据红（没有 locale 目录也必须判到，
  这是 2026-11-19 修过的 bug：crash 检查一度放在 locale 循环里，纯 crash 反例会漏判）。
