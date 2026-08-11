# RET-01 单张照片取回=使用动作　级别 L2　【链 2 首卡】

## 语义基准

docs/product/2026-08-11-chain2-decisions.md ①③——取回是为了**用**：
「保存到相册」+「用其他应用打开」，覆盖 删后要用/要家人的照片/拿去修图
三场景。批量恢复向导**不在本卡**。

## 修法

- 手机查看页（时间线点开的大图/视频页）加两动作：
  ①「保存到相册」——blob 拉原图 → 写 MediaStore（含 mime/时间元数据，
  尽量保原拍摄时间）；②「用其他应用打开」——临时文件 + FileProvider +
  系统分享/打开面板。
- **MOB-04 红线**：临时文件即用即清（面板关闭/进程重启清理），绝不建
  长期原图缓存；「保存到相册」是用户显式动作，落的是 MediaStore 不是
  我们的缓存。
- 拉取链路复用 T-033 原图 blob 拉取，不加协议动词。
- 防循环不用做事（幂等去重天然防住），但集成测试要钉住：存回相册 →
  再备份 → daemon 零新增（防未来改坏）。

## 可执行验收

1. 模拟器：家人照片（非本机）→ 保存到相册 → 系统相册可见、时间元数据
   合理（贴截图）。
2. 「用其他应用打开」拉起系统面板（贴截图）；操作后临时目录零残留
   （ls 贴输出）。
3. 集成测试：存回→再备份→offered 含它但 ingested=0 duplicates=1（防循环钉死）。
4. 断网点两动作 → 人话错误不崩。
5. android 全量绿。

## 反证

临时文件清理去掉 → 验收 2 的 ls 必有残留（贴对照后还原）。

## 收尾
CI 绿；PROGRESS/NEXT/ROADMAP；卡移 done/。ROADMAP 另记一行「恢复向导
（换机整库恢复）——后置」。

---

## 验收记录（2026-08-12 Salamira）

**实现**：
- 新增 `ui/AssetActions.kt`：`saveToGallery`（API 29+ MediaStore
  RELATIVE_PATH+IS_PENDING 免权限 / API 26-28 DATA 路径+WRITE_EXTERNAL_STORAGE
  权限+MediaScanner 广播）、`openWithAppIntent`（FileProvider+ACTION_VIEW）、
  `sniffMimeFromHeader`（文件头魔数嗅探真实 MIME——asset.mediaType 只有
  photo/video 粗类，保存需真实 mime；纯函数 JVM 可测）、`mimeExtension`。
- 查看页两个动作：PhotoViewer + VideoScreen 底部胶囊按钮（ViewerAction，
  与 FilterChip 同族）；视频 Ready 前不显示动作。
- MOB-04 红线：原图下载到 cacheDir/share/（系统可清=进程重启兜底）；
  每次使用前清旧残留（即用即清）；保存走 MediaStore 后立即删临时文件；
  打开外部 App 面板关闭回调再清一次。
- manifest 加 WRITE_EXTERNAL_STORAGE（maxSdk 28，API 26-28 分支）；
  file_paths.xml 加 share cache-path。
- i18n：5 个新 key en/zh 对称（StringsSymmetryTest 兜底）。
- 防循环钉子：DaemonBackupTest 显式断言 rerun offered=12 ingested=0
  duplicates=12（存回=同 hash 重入扫描集→daemon 零新增）。

**验证**：
- `./gradlew :app:compileDebugKotlin :app:compileDebugUnitTestKotlin` 绿
  （两次编译错误均为缺 import，修后即过）。
- `./gradlew :app:testDebugUnitTest --rerun-tasks`：**140/140 全绿**
  （含新增 AssetActionsTest 8 项：JPEG/PNG/WebP/HEIC/MP4 魔数、粗类兜底、
  空文件兜底、扩展名映射；StringsSymmetryTest 双语对称过）。

**真机待验（C 线挂账）**：
1. 家人照片（非本机）→ 保存到相册 → 系统相册可见、时间元数据合理（截图）。
2. 用其他应用打开拉起系统面板（截图）；操作后临时目录零残留（ls 输出）。
3. 断网点两动作 → 人话错误不崩。
