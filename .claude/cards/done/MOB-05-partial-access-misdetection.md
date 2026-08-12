# MOB-05 部分授权误判死循环（完整授权被当成部分授权）　级别 L1　【用户真机报告 2026-08-12】

## 根因

`TriggerPolicy.isPartialMediaAccess`（MOB-02 引入）判定式写反了：

```kotlin
sdkInt >= 34 && imagesGranted && visualSelectedGranted   // 旧
```

假设"完整授权只给 READ_MEDIA_IMAGES/VIDEO，不给 READ_MEDIA_VISUAL_USER_SELECTED"，
但真机行为（用户报告 + 官方文档核对）不是这样：
`READ_MEDIA_VISUAL_USER_SELECTED` 一旦被系统授予过（比如早先选过"选择照片"），
之后即使在系统设置里升级成"允许所有照片"，这个权限也**不会被系统撤销**——
它会一直和 `READ_MEDIA_IMAGES` 同时保持已授予。旧判定式因此几乎永远为真，
把完整授权误判成部分授权，后果连锁：

1. `enterBucketPicker` / `bucketMediaPermission` 回调判 `hasPartialMediaAccess()`
   为真 → 永远被弹回 Home 引导卡，进不了 `Screen.Buckets`；
2. 就算某次绕进了 `BucketScreen`，`onDone` 里同一判定为真 → 选择被直接丢弃
   不落盘，退回 Home；
3. Home 引导卡的按钮把用户送去系统设置重新授权 → 系统弹出它自己的"部分照片"
   选择器（Recent/Albums 两个 tab，只能挑单张照片，不能整相册授权）——用户
   看到的"只能选照片"其实是系统的限量选择 UI，不是我们相册页的 bug，而是
   被误判逼进这个系统流程的后果。

官方检测顺序（developer.android.com/about/versions/14/changes/partial-photo-video-access）：
先判 `READ_MEDIA_IMAGES`/`VIDEO` 授予 → 完整访问；否则才判
`READ_MEDIA_VISUAL_USER_SELECTED` 授予 → 部分访问。`images` 授予本身就是
完整访问的充分条件，与 `visualSelected` 是否历史遗留无关。

## 修法

`TriggerPolicy.kt`：

```kotlin
sdkInt >= 34 && !imagesGranted && visualSelectedGranted
```

调用侧（`MainActivity.hasPartialMediaAccess` 及其所有消费点）零改动——
纯函数签名不变，只改内部判定式方向。

## 可执行验收

1. `TriggerPolicyTest.partial_access_detection` 按新语义重写：
   `imagesGranted=true` 的两种组合恒 `false`（不是部分）；
   `imagesGranted=false, visualSelectedGranted=true` 才是 `true`（真部分）。
2. Android 全量单测绿。
3. 反证：把 `!imagesGranted` 的 `!` 去掉 → `partial_access_detection` 必红。
4. 真机验收（挂用户）：已完整授权的设备打开「选择备份的相册」——直接进
   相册列表，不再弹引导卡/不再被赶去系统设置；选择相册后 `onDone` 保存
   生效，返回 Home 后引导卡消失。

## 收尾
CI 绿；PROGRESS/NEXT/ROADMAP 一行；卡移 done/。

---

## ✅ 验收记录（2026-08-12）

- 实现：`TriggerPolicy.kt` 判定式取反（`!imagesGranted && visualSelectedGranted`）；
  `TriggerPolicyTest.partial_access_detection` 同步改写为新语义，反证已在
  测试里显式对照（旧语义两条断言方向互换）。
- 依据核对：WebFetch 官方文档确认检测顺序（images/video granted → 完整；
  否则 visual_selected granted → 部分），与本卡修法一致。
- 测试：`./gradlew :app:testDebugUnitTest` 全量 **27/27 test suite 绿**
  （`TriggerPolicyTest` 11/11，含改写后的 `partial_access_detection`）。
- 消费点核查：`grep -rn "PartialMediaAccess"` 确认唯一调用方是
  `MainActivity.hasPartialMediaAccess`，无 BackupWorker/BackupRunner 旁路。
- CI：push `68b8f2d` → main，ci-android #3 绿（1m36s）。
- 真机复现前提（pm grant 实测，用户授权连接测试机后）：先 grant
  `READ_MEDIA_VISUAL_USER_SELECTED` 单独授予（模拟「选择照片」），再
  额外 grant `READ_MEDIA_IMAGES`/`VIDEO`（模拟升级为「允许所有照片」，
  不撤销前者）→ `dumpsys package` 确认三个权限均 `granted=true` 同时
  成立——证实了本卡假设的真机行为（visual_selected 不随升级被撤销）。
  debug 包装机、启动无崩溃（Welcome 页正常）。
- **用户真机确认（2026-08-12）**：日常使用设备上"可以选择相册了"——
  死循环解除。本卡闭环。
