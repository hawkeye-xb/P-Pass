# android/a11y-semantics 判定回放（#1801）

证据树取自 #1801 第三轮真机 dump（origin/main b249aaf3 的 debug 包，三星 SM-S928N @450dpi），
只用于离线回放判定（`tools/test-e3.sh` 与 `tools/e3/run judge`），不是新的真机证据。

每个反例只让一条判据出错，删掉或放宽那条判据，回放就会红：

- `pass/`：zh-CN 与 en-US 各一套设置页 + 范围页（open/toggled 两态齐）。
  en-US 的 `scope-toggled.xml` 与 `scope-open.xml` 是同一份 dump（EN 1.08x 只截了一张范围页，
  该 dump 里四张卡已同时有选中与未选两态，判据按两份 dump 合计判两态，够用）。
- `fail-switchrow-unlabeled/`：settings.xml 里「自动备份」的 label 文本抹掉——开关行名称没合并判据红。
- `fail-scope-no-checkable/`：两份范围页的相册卡 checkable 属性剥掉——「选中语义必须在卡上」判据红。
- `fail-entry-unclickable/`：「从相册选择」行的 clickable 改 false——入口行整行可点判据红。
- `fail-touchtarget/`：「自动备份」行 bounds 高度改成 36px（≈13dp）——触控目标 ≥48dp 判据红。
