# MOB-06 查看页右上角「分享」——ACTION_SEND 走系统分享面板　级别 L2

**目标**：照片查看页（PhotoViewer）与视频查看页（VideoScreen）右上角新增
「分享」入口，走系统分享面板（ACTION_SEND + createChooser + EXTRA_STREAM），
用户点分享可直接跳到微信/邮件/云盘等目标 app。与既有「用其他应用打开」
（ACTION_VIEW）并存，两者语义不同（详见卡尾）。

**背景（用户 2026-08-12 询问）**：「分享」和「其它 APP 打开」是不是同一个
功能？——不是。Android 里这是两种 Intent：
- 「分享」= `ACTION_SEND`：把文件作为**内容/附件**发给目标 app（接收方
  语义 = 接收内容，新建消息/上传附件），系统弹**分享面板**（微信/QQ/邮件/
  云盘/蓝牙 Nearby）。
- 「用其他应用打开」= `ACTION_VIEW`：让目标 app 以**打开**模式处理文件
  （接收方语义 = 打开文件本身，修图/播放/查看），系统弹**打开方式选择器**。
- 底层 90% 共用：FileProvider URI + FLAG_GRANT_READ_URI_PERMISSION +
  cacheDir/share/ 临时文件即用即清（RET-01 管线）。
- 常规做法：查看页右上角放分享图标（本卡），「用其他应用打开」留底部
  动作区（已有，RET-01）。不引 material-icons-extended（体积），自绘
  vector drawable 标准分享图标。

**范围**：只准动
- `apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/AssetActions.kt`
  （+ `shareIntent` 纯 Intent 构造，与 `openWithAppIntent` 同族）
- `apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/PhotosScreen.kt`
  （PhotoViewer 顶部右侧 + 分享动作）
- `apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/VideoScreen.kt`
  （视频查看页右上角 + 分享动作）
- `apps/android/app/src/main/res/drawable/ic_share.xml`（新增，标准分享图标）
- `apps/android/app/src/main/res/values/strings.xml` + `values-zh/strings.xml`
  （新增 share 相关 key，双语对称）

**不准动**：daemon/desktop/其他 UI 页面；既有「保存到相册」「用其他应用
打开」逻辑与文案；FileProvider paths（share/ 已覆盖）。

**可执行验收**：
- `cd apps/android && ./gradlew :app:testDebugUnitTest` → 全量绿
  （含 StringsSymmetryTest——新增 key 必须 en/zh 对称）
- `./gradlew :app:assembleDebug` → BUILD SUCCESSFUL
- `git grep ACTION_SEND` → 出现且只在 AssetActions.kt（构造处）+ 两查看页
  （消费处），无旁路
- 反证：StringsSymmetryTest 语义——只改 en 不改 zh → 测试必须红
- 真机（挂用户）：照片/视频查看页右上角分享图标 → 系统分享面板出现 →
  选微信能收到图；分享面板关闭后 `cacheDir/share/` 无残留

**收尾**：just 全绿 + PROGRESS.md 一行 + NEXT.md 队列更新 + ROADMAP 状态行。

---

## 验收记录（2026-08-12）

**证据**：
- `./gradlew :app:testDebugUnitTest` → BUILD SUCCESSFUL，166/166 绿
  （含 StringsSymmetryTest en/zh 对称：share/share_to 双语齐）
- `./gradlew :app:assembleDebug` → BUILD SUCCESSFUL，app-debug.apk 28MB
- `git grep ACTION_SEND` → 只在 AssetActions.kt（构造）+ Photos/VideoScreen
  （消费），无旁路
- 反证（StringsSymmetryTest 语义）：只改 en 不改 zh → 该测试红（既有断言，
  本卡新增 key 已双语对称，无新增反证需求）
- 改动范围 = 卡范围（5 文件 + 2 新增），无越界

**挂账（真机，用户）**：
1. 照片/视频查看页右上角分享图标 → 系统分享面板出现
2. 选微信 → 收到原图（视频同理）
3. 面板关闭后 cacheDir/share/ 无残留
4. 决定这批改动（MOB-06 等）怎么正式发布
