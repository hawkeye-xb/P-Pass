# I18N-01 空相册名的兜底文案硬编码成中文　级别 L3

> 🟡 状态：代码已合入，等英文系统真机验收
> 级别：**L3** · 阻塞：无

## 问题

验收人反馈（2026-08-26 真机 0.4.0-test.8，回归步骤 #9）：

> 「选中相册（这里也应该多语言支持？）」

选相册页的文案全部走 `stringResource`，**只漏了一处**：

`apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/MediaScanner.kt:84`

```kotlin
val name = cur.getString(nameIdx)?.takeIf { it.isNotBlank() } ?: "未命名"
```

`MediaScanner` 是纯数据层（没有 `Context`），所以当初图省事把兜底文案写在了
这里。英文机器上这一格会显示中文。

## 要做的

兜底不该由数据层决定。`MediaScanner.Bucket.name` 改成可空（空名就是空名，
那是事实），由 `BucketScreen` 渲染时用 `stringResource(R.string.bucket_unnamed)`
补上。新增 `bucket_unnamed` 两份文案（`values/` = "Unnamed"，`values-zh/` = "未命名"）。

## 验收标准

- [ ] 单测：`listBuckets` 对空名相册返回 `name == null`（不再返回中文字面量）
- [x] `MediaScanner` 不再含中文兜底；其余既有主 Kotlin 中文硬编码已拆为 I18N-02，避免扩大本卡范围
- [ ] 真机（留给验收人）：系统语言切英文 → 选相册页没有中文
