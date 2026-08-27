# WATCH-06 相册 = 目录　级别 L3（backlog，新能力）

> 用户 2026-08-21：「暂时不需要的内容就先不开发，挑重点的开发」→ **先不做**，
> 只记账。

## 缺口

`WATCH-04` 落地后，用户在 Finder 里建的目录会被完整保留 —— 但**界面上完全
看不见**：

- 桌面端没有相册概念（`grep -rl "bucket|album|相册" apps/desktop/src/` **零命中**）
- 手机端收到的 `AssetMeta`（`crates/proto/src/msgs.rs`）只有
  `hash / taken_at / media_type / 宽高 / 字节`，**连路径字段都没有**

## 做法：照 Android 学

Android 的「相册」**就是目录** —— `MediaStore.MediaColumns.BUCKET_DISPLAY_NAME`
字面意思就是文件所在文件夹的名字，它没有独立的相册实体。我们自己的
`apps/android/.../MediaScanner.kt` 就是在读这两列（`BUCKET_ID` /
`BUCKET_DISPLAY_NAME`）。

所以：

> **你在 Finder 里建「我的婚礼」目录，就是建了一个相册。**

零额外 UI 概念，`WATCH-04` 的宽容规则让这件事有意义。

## 需要动的

1. `AssetMeta` 加一个「所在目录」字段（wire 变更，要考虑老客户端）
2. daemon 侧按目录聚合的查询（数量 + 封面）
3. 桌面/手机的相册入口

## 不要做的

**不要用软链在文件系统里"物化"视图**（比如建一个 `files/` 树软链所有照片）。
理由：

- 软链是**第二个路径**，`WATCH-04` 刚立的「一个路径只能被一条索引行占用」
  当场破产
- watcher 遍历树：跟随软链 → 每张照片数两次；不跟随 → 那个视图是空的；
  还有环的风险
- Windows 建软链需要管理员或开发者模式，`release.yml` 有 `windows-x64` job，
  这条到那儿直接死
- 删掉目标 → 悬挂链接，在用户眼里还是个文件
- Android 自己也不物化：`MediaStore.Images` 是**一个查询**，不是一个装满
  链接的文件夹

**视图活在查询里，不活在目录里。**
