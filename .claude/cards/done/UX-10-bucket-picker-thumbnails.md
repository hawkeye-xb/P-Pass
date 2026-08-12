# UX-10 相册选择页封面缩略图　级别 L1　【用户产品反馈 2026-08-12】

## 背景

用户走查完 UX-09 后追问：相册选择页（BucketScreen）能不能像系统相册
选择器一样有缩略图，而不是纯文字列表——直觉准确：`BucketScreen` 就是
自己拼的 `LazyColumn`（Checkbox + 相册名 + 张数），从 T6 落地起就没有
任何封面图逻辑。

## 修法

1. `MediaScanner.Bucket` 加 `coverUri: Uri?` 字段——`listBuckets()`
   在原有按 bucket 分组的查询里顺手多投影 `_ID` + `DATE_ADDED`，跨
   图片/视频两个 collection 比较日期，取全局最新一条的 uri 作为封面
   代表（老数据/异常时为 null，UI 退化为空白封面，不阻塞选择流程）。
2. `BucketScreen.kt` 新增 `BucketCover` composable：API 29+ 用官方
   `ContentResolver.loadThumbnail`（图片/视频统一接口）解码 96px 封面；
   低于 29 的设备封面留空（纯视觉锚点，不为老设备多维护一条解码路径）。
   每行插入一个 48dp 圆角封面图。
3. **复用而非新开缓存**：第一版直接在 BucketScreen 里开了个独立
   `LruCache<Long, Bitmap>`，撞上 `CacheRedlineTest.noDiskThumbCacheInSources`
   的断言——「LruCache 声明全工程只能有 PhotosScreen.kt 一处」，测试
   红了。改为把 `PhotosScreen.kt` 的 `thumbCache` 从 `private` 开放成
   `internal`（全 App 唯一内存缩略图缓存），BucketScreen 复用同一实例，
   key 加 `"bucket:"` 前缀避免和远端 hash key 撞车。这条红线测试没有为
   了迎合新代码放宽——按测试原意改代码，不改测试。
4. **走查追加（用户看完首版截图后的三点反馈）**：
   ①Checkbox 挪到缩略图左侧（阅读顺序：先看到"要不要选"，再看图认
   相册，和系统相册选择器一致，之前顺序反了）；
   ②「全选/清空」整行删除——选相册是要逐个决策的事，不该给一键清空的
   意外风险；真想全选，相册数量有限，自己点几下不麻烦（连带删掉
   `selectAll` 状态变量与 `bucket_select_all`/`bucket_clear` 两个只在
   这一处用的字符串资源）；
   ③底部改「取消 1/4 + 备份 3/4」单行（原来是「全选/清空」+「取消」
   各占一半、下面再叠一条独立的全宽「备份」按钮，三行变一行）——备份
   是本页主动作，取消只是退路，宽度该有落差不该对半分。

## 可执行验收

1. `CacheRedlineTest`（含改前踩雷、改后转绿的完整过程）+ 全量单测绿。
2. 真机（挂用户）：相册选择页每行左侧出现封面缩略图，和系统相册选择器
   视觉体感一致；老相册/空相册优雅退化为空白格，不崩不白屏。

## 收尾
android 全量单测绿；CI 待推 main 后盯 ci-android。

---

## ✅ 验收记录（2026-08-12）

- 实现：见「修法」三项。第一版触发 `CacheRedlineTest` 红线（新开
  第二个 LruCache），当场定位根因（守卫测试断言唯一声明处）并改为
  复用 `PhotosScreen.thumbCache`，全量单测转绿——闭环调试过程本身即
  验证证据（复现→隔离→假设→测试→验证）。
- debug 包已 `adb install -r` 装到用户日常用的真机。
- CI：push `28c4576` → main，ci-android #5 绿（1m42s）。
- 走查追加三点（Checkbox 移位/删全选清空/取消 1/4+备份 3/4）已改完，
  单测重跑绿（`StringsSymmetryTest` 确认删除的两个字符串键 en/zh 同步
  消失，没留孤儿），debug 包已重新装机。
- 挂账（真机，用户）：视觉效果 + 老设备退化观感待确认。
