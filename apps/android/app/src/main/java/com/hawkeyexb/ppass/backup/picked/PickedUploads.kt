package com.hawkeyexb.ppass.backup.picked

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.MediaStore
import android.provider.OpenableColumns

/**
 * #1272 挑几张传：App 侧入口。选择器给的 URI 在这里登记成一批手选订单，之后由 [com.hawkeyexb.ppass.backup.flow.FlowEngine]
 * 在同一条循环里（手选优先）传走。**不需要任何照片权限**；也**不会**写进备份范围。
 */
object PickedUploads {
    /** 一次最多挑几张：Android 系统选择器的上限（AOSP `PICK_IMAGES_MAX_LIMIT`），iOS 的 selectionLimit 与之一致。 */
    const val MAX_PICK = 100

    @Volatile private var store: SqlitePickedStore? = null

    fun store(context: Context): PickedStore =
        store ?: synchronized(this) { store ?: SqlitePickedStore.open(context).also { store = it } }

    /**
     * 登记一批。选完不复制原图：对每个 URI 申请持久读授权（重启后仍能读；失败不致命，选择器本身的授权在进程存活期内有效），
     * 元数据读一次存下来。返回批里的张数。
     */
    fun enqueue(context: Context, uris: List<Uri>, limit: Int = MAX_PICK): Int {
        val app = context.applicationContext
        val resolver = app.contentResolver
        val items = uris.take(limit).map { uri ->
            runCatching { resolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
            describe(app, uri)
        }
        if (items.isEmpty()) return 0
        store(app).addBatch(items)
        return items.size
    }

    /**
     * #1272 §4「有限访问」：开启自动备份时用户只授权了部分照片——把系统此刻允许我们看见的图片按手选链路传一次
     * （不进备份范围、以后追加授权的不会自动跟着传）。返回实际登记的张数（Android 的有限授权是累计的，以此为准）。
     */
    fun enqueueAllowedImages(context: Context): Int {
        val app = context.applicationContext
        val uris = runCatching {
            app.contentResolver.query(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                arrayOf(MediaStore.Images.Media._ID),
                null,
                null,
                "${MediaStore.Images.Media._ID} ASC",
            )?.use { c ->
                buildList {
                    while (c.moveToNext()) add(android.content.ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, c.getLong(0)))
                }
            }
        }.getOrNull().orEmpty()
        return enqueue(app, uris, limit = Int.MAX_VALUE)
    }

    /** 这张传完（不论结局）：放掉持久授权。系统对每个 App 最多保留 5000 个，不放会越攒越多。 */
    fun release(context: Context, uri: String) {
        runCatching {
            context.applicationContext.contentResolver.releasePersistableUriPermission(Uri.parse(uri), Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
    }

    /** 断开配对：清空手选表并放掉所有 URI 授权。 */
    fun discardAll(context: Context) {
        runCatching { store(context).clearAll().forEach { release(context, it) } }
    }

    private fun describe(context: Context, uri: Uri): NewPicked {
        val resolver = context.contentResolver
        var name = ""
        var size = 0L
        var taken = 0L
        runCatching {
            resolver.query(uri, null, null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    c.getColumnIndex(OpenableColumns.DISPLAY_NAME).takeIf { it >= 0 }?.let { name = c.getString(it).orEmpty() }
                    c.getColumnIndex(OpenableColumns.SIZE).takeIf { it >= 0 }?.let { size = c.getLong(it) }
                    c.getColumnIndex(MediaStore.MediaColumns.DATE_TAKEN).takeIf { it >= 0 }?.let { taken = c.getLong(it) }
                }
            }
        }
        val mime = runCatching { resolver.getType(uri) }.getOrNull().orEmpty().ifBlank { "image/*" }
        return NewPicked(
            uri = uri.toString(),
            fileName = name.ifBlank { uri.lastPathSegment.orEmpty() },
            mimeType = mime,
            sizeBytes = size,
            captureAtMs = taken,
        )
    }
}
