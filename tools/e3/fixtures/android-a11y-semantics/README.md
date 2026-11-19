# android/a11y-semantics 判定回放（#1801）

证据树取自 #1801 第四轮真机 dump（本分支 ci/1801-1792-talkback 的 debug 包，三星 SM-S928N @450dpi，
Android 16），只用于离线回放判定（`tools/test-e3.sh` 与 `tools/e3/run judge`）。真机原始输出
（png / logcat / 逐页 xml / flip.txt）在本机 `.evidence/1801/round4/`，不进 git。

每个反例只让一条判据出错，删掉或放宽那条判据，回放就会红：

- `pass/`：zh-CN 与 en-US 各一套设置页 + 范围页（open/toggled 两态齐，flip.txt 记下被点卡的
  bounds 与点前 checked）+ 两个单次入口选择器页（系统 Photo Picker / SAF）+ 看图页。
- `fail-switchrow-unlabeled/`：settings.xml 里「自动备份」的 label 文本抹掉——开关行名称没合并判据红。
- `fail-scope-no-checkable/`：只把被点的那张卡（flip.txt 认卡凭据）的 checkable 剥掉，
  其余卡的选中/未选态原样保留——「选中语义必须在卡上」判据红（剥光所有卡会让别的判据跟着红，
  就证不了这一条本身）。
- `fail-entry-unclickable/`：「从相册选择」行的 clickable 改 false——入口行整行可点判据红。
- `fail-touchtarget/`：「自动备份」行 bounds 高度改成 36px（≈13dp）——触控目标 ≥48dp 判据红。
- `fail-flip-noop/`：scope-toggled.xml 与 scope-open.xml 是同一份 dump（点击 no-op）——
  「同一张卡 checked 必须翻转」判据红（两份 dump 合计有选中与未选两态，判不出点击没生效）。
- `fail-picker-noclickable/`：picker-photos.xml 所有节点 clickable=false——「点进了选择器」判据红。
- `fail-viewer-noback/`：viewer.xml「返回」节点 clickable=false——看图页出口判据红。
