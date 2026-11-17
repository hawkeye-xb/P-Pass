// M5（全页面状态稿）：选相册——2 列封面卡片网格，右上角圆形勾选角标，
// 单个主按钮（取代旧的竖排复选框列表 + "取消/备份N个相册"两按钮）。共用入口：onboarding 配对成功后 与
// 设置页"备份哪些照片"重选，都是这一个 composable。
// #1263：标题「备份哪些照片」；相册之外加一行时间二选一（从今天起 / 全部）；删掉底部汇总句（每个相册有张数，
// Wi-Fi 条件在设置里）；按钮首次叫「开始备份」，编辑时叫「保存」，其余完全相同。不显示大小（iOS 没有公开接口，两端对齐）。
package com.hawkeyexb.ppass.ui

import android.content.ContentResolver
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.util.Size
import androidx.compose.foundation.Image
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.backup.MediaAccess
import com.hawkeyexb.ppass.backup.MediaScanner
import com.hawkeyexb.ppass.backup.ScopeTime
import com.hawkeyexb.ppass.backup.newAlbumIds
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * UX-10: 相册封面缩略图——来源是手机本机 MediaStore（不是家庭云端
 * 数据），不受 MOB-04 红线约束（那条红线管的是"别把家人照片在手机上
 * 存第二份"，这里解码的图本来就已经在手机本地）；但仍复用 PhotosScreen
 * 的全 App 唯一内存缓存（CacheRedlineTest 断言只准一处 LruCache 声明），
 * key 加 `"bucket:"` 前缀避免和远端缩略图的 hash key 撞车。
 */
private fun bucketCoverCacheKey(bucketId: Long, displaySize: IntSize) =
    "bucket:$bucketId:${displaySize.width}x${displaySize.height}"

/** API 29+ 用官方 loadThumbnail（图片/视频统一接口）；更早的 API 让
 *  封面留空——这是纯视觉锚点，不是必需功能，不为老设备多维护一条
 *  解码路径。 */
private fun decodeBucketCover(
    resolver: ContentResolver,
    uri: Uri,
    displaySize: IntSize,
): Bitmap? = runCatching {
    if (Build.VERSION.SDK_INT >= 29) {
        resolver.loadThumbnail(uri, Size(displaySize.width, displaySize.height), null)
    } else {
        null
    }
}.getOrNull()

@Composable
private fun BucketCoverImage(bucketId: Long, coverUri: Uri?, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    var displaySize by remember { mutableStateOf(IntSize.Zero) }
    val cacheKey = bucketCoverCacheKey(bucketId, displaySize)
    // LINT-01: ProduceStateDoesNotAssignValue 误报——`value = ...` 裹在
    // `if (value == null && ...)` 条件分支里，lint 的静态检查器看不出
    // 条件分支内的赋值（缓存命中时本来就不该重新赋值，这是有意为之）。
    @Suppress("ProduceStateDoesNotAssignValue")
    val bmp by produceState(
        initialValue = thumbCache.get(cacheKey),
        key1 = coverUri,
        key2 = displaySize,
    ) {
        if (value == null && coverUri != null && displaySize != IntSize.Zero) {
            value = withContext(Dispatchers.IO) {
                runCatching {
                    decodeBucketCover(context.contentResolver, coverUri, displaySize)
                }.getOrNull()
            }?.also { thumbCache.put(cacheKey, it) }
        }
    }
    Box(
        modifier
            .onSizeChanged { displaySize = it }
            .background(PPColor.Linen),
    ) {
        val b = bmp
        if (b != null) {
            Image(
                bitmap = b.asImageBitmap(), contentDescription = null,
                modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop,
            )
        }
    }
}

/** 右上角勾选角标——设计稿：选中=墨底白勾，未选中=半透明纸底描边圈。 */
@Composable
private fun SelectBadge(selected: Boolean, modifier: Modifier = Modifier) {
    Box(
        modifier
            .size(22.dp)
            .clip(CircleShape)
            .background(if (selected) PPColor.Ink else PPColor.PaperDim)
            .then(
                if (selected) Modifier
                else Modifier.border(1.5.dp, PPColor.BorderStrong, CircleShape)
            ),
        contentAlignment = Alignment.Center,
    ) {
        if (selected) {
            Text("✓", fontSize = 12.sp, fontWeight = FontWeight.Bold, color = PPColor.Paper)
        }
    }
}

@Composable
private fun SourceTypeGlyph(folder: Boolean) {
    val color = PPColor.Ink40
    Canvas(Modifier.size(16.dp)) {
        val stroke = Stroke(width = 1.4.dp.toPx())
        fun line(path: Path, x1: Float, y1: Float, x2: Float, y2: Float) {
            path.moveTo(x1.dp.toPx(), y1.dp.toPx())
            path.lineTo(x2.dp.toPx(), y2.dp.toPx())
        }
        if (folder) {
            val outline = Path()
            line(outline, 1f, 4f, 6f, 4f)
            line(outline, 6f, 4f, 8f, 6f)
            line(outline, 8f, 6f, 15f, 6f)
            line(outline, 15f, 6f, 15f, 14f)
            line(outline, 15f, 14f, 1f, 14f)
            line(outline, 1f, 14f, 1f, 4f)
            drawPath(outline, color, style = stroke)
        } else {
            val back = Path()
            line(back, 4f, 1f, 15f, 1f)
            line(back, 15f, 1f, 15f, 12f)
            line(back, 15f, 12f, 4f, 12f)
            line(back, 4f, 12f, 4f, 1f)
            val front = Path()
            line(front, 1f, 4f, 12f, 4f)
            line(front, 12f, 4f, 12f, 15f)
            line(front, 12f, 15f, 1f, 15f)
            line(front, 1f, 15f, 1f, 4f)
            drawPath(back, color, style = stroke)
            drawPath(front, color, style = stroke)
        }
    }
}

/** #1794：没有相册权限时相册区的现状说明 + 申请入口（样式同首页权限卡）。 */
@Composable
private fun AlbumNoAccessNotice(onRequest: () -> Unit) {
    Surface(
        color = PPColor.ActBg,
        shape = RoundedCornerShape(16.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(16.dp)) {
            Text(
                stringResource(R.string.no_media_access_title),
                fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = PPColor.Ink,
            )
            Spacer(Modifier.height(6.dp))
            Text(
                stringResource(R.string.scope_album_no_access_body),
                fontSize = 13.sp, color = PPColor.Ink40,
            )
            Spacer(Modifier.height(10.dp))
            OutlinedButton(
                onClick = onRequest,
                modifier = Modifier.height(40.dp),
                shape = RoundedCornerShape(14.dp),
                border = androidx.compose.foundation.BorderStroke(1.dp, PPColor.Act.copy(alpha = 0.4f)),
                colors = ButtonDefaults.outlinedButtonColors(contentColor = PPColor.Act),
            ) { Text(stringResource(R.string.scope_album_no_access_action), fontSize = 15.sp, fontWeight = FontWeight.Bold) }
        }
    }
}

@Composable
private fun BucketCard(
    bucket: MediaScanner.Bucket,
    selected: Boolean,
    isNew: Boolean,
    isFolder: Boolean,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
    secondaryActionLabel: String? = null,
    onSecondaryAction: (() -> Unit)? = null,
    onToggle: () -> Unit,
) {
    Column(
        Modifier
            .clip(RoundedCornerShape(16.dp))
            .background(PPColor.Paper)
            .border(
                2.dp,
                if (selected) PPColor.Ink else PPColor.Border,
                RoundedCornerShape(16.dp),
            )
            .clickable(onClick = onToggle),
    ) {
        Box {
            BucketCoverImage(
                bucket.id, bucket.coverUri,
                modifier = Modifier.fillMaxWidth().aspectRatio(1.6f),
            )
            SelectBadge(selected, Modifier.align(Alignment.TopEnd).padding(8.dp))
        }
        Column(Modifier.height(72.dp).padding(12.dp, 9.dp, 12.dp, 11.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                SourceTypeGlyph(isFolder)
                Text(
                    bucket.name ?: stringResource(R.string.bucket_unnamed),
                    fontSize = 14.5.sp, fontWeight = FontWeight.SemiBold,
                    color = PPColor.Ink,
                    modifier = Modifier.weight(1f).padding(start = 6.dp),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (isNew) {
                    Text(
                        stringResource(R.string.bucket_new),
                        fontSize = 11.sp, fontWeight = FontWeight.Bold,
                        color = PPColor.Waiting,
                        modifier = Modifier.padding(start = 6.dp),
                    )
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    stringResource(R.string.bucket_count, bucket.count),
                    fontSize = 12.5.sp, color = PPColor.Ink40,
                    modifier = Modifier.weight(1f),
                )
                if (actionLabel != null && onAction != null) {
                    Text(
                        actionLabel,
                        fontSize = 12.sp, color = PPColor.Act,
                        modifier = Modifier.clickable(onClick = onAction).padding(start = 8.dp),
                    )
                }
                if (secondaryActionLabel != null && onSecondaryAction != null) {
                    Text(
                        secondaryActionLabel,
                        fontSize = 12.sp, color = PPColor.Act,
                        modifier = Modifier.clickable(onClick = onSecondaryAction).padding(start = 8.dp),
                    )
                }
            }
        }
    }
}

/**
 * #1794：相册区能不能选。没有相册权限时不给选，只在相册区显示现状与申请入口；
 * 文件夹区和「添加文件夹」不受影响（对齐 iOS，范围页始终能进）。
 */
internal fun bucketScreenOffersAlbumChoices(access: MediaAccess): Boolean = access != MediaAccess.NONE

/**
 * 整机空文案（「手机上没有照片或视频」）只在真读得到照片、且相册与文件夹都为空时成立；
 * 没有相册权限时读不到照片，不能说成整机没有照片。
 */
internal fun bucketScreenEmptyNoticeVisible(
    bucketsEmpty: Boolean,
    foldersEmpty: Boolean,
    access: MediaAccess,
): Boolean = bucketsEmpty && foldersEmpty && bucketScreenOffersAlbumChoices(access)

data class FolderBucketUi(
    val key: String,
    val bucket: MediaScanner.Bucket,
    val registered: Boolean,
    val needsPermission: Boolean = false,
)

@Composable
fun BucketScreen(
    buckets: List<MediaScanner.Bucket>,
    selected: Set<Long>,
    initialTime: ScopeTime = ScopeTime.SINCE_TODAY,
    sinceLabel: String,
    firstTime: Boolean,
    knownBuckets: Set<Long>? = null,
    folderBuckets: List<FolderBucketUi> = emptyList(),
    selectedFolderKeys: Set<String> = emptySet(),
    saving: Boolean = false,
    albumAccess: MediaAccess = MediaAccess.FULL,
    onRequestAlbumAccess: () -> Unit = {},
    onAddFolder: () -> Unit = {},
    onRemoveFolder: (String) -> Unit = {},
    onReauthorizeFolder: (String) -> Unit = {},
    onDone: (Set<Long>, Set<String>, ScopeTime) -> Unit,
    onCancel: () -> Unit,
) {
    var checked by remember { mutableStateOf(selected) }
    var checkedFolders by remember { mutableStateOf(selectedFolderKeys) }
    var seenFolderKeys by remember { mutableStateOf(selectedFolderKeys) }
    var removing by remember { mutableStateOf<FolderBucketUi?>(null) }
    var time by remember { mutableStateOf(initialTime) }
    val newIds = newAlbumIds(buckets.map { it.id }.toSet(), knownBuckets)
    val offersAlbums = bucketScreenOffersAlbumChoices(albumAccess)

    LaunchedEffect(folderBuckets) {
        val pending = folderBuckets.filter { !it.registered && it.key !in seenFolderKeys }.map { it.key }
        if (pending.isNotEmpty()) {
            seenFolderKeys = seenFolderKeys + pending
            checkedFolders = checkedFolders + pending
        }
    }

    PPScreen {
        androidx.compose.material3.ProvideTextStyle(
            androidx.compose.material3.LocalTextStyle.current.copy(fontFamily = PPFont.Sans),
        ) {
        Column(Modifier.fillMaxSize().padding(24.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "‹", fontSize = 24.sp, color = PPColor.Ink,
                    modifier = Modifier.clickable(onClick = onCancel).padding(4.dp, 0.dp, 10.dp, 0.dp),
                )
                Text(stringResource(R.string.backup_scope), fontSize = 24.sp, fontFamily = PPFont.Serif, color = PPColor.Ink)
            }
            Spacer(Modifier.height(12.dp))
            Row(horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(8.dp)) {
                PhotoFilterChip(sinceLabel, time == ScopeTime.SINCE_TODAY) { time = ScopeTime.SINCE_TODAY }
                PhotoFilterChip(stringResource(R.string.scope_time_all), time == ScopeTime.ALL) { time = ScopeTime.ALL }
            }
            Spacer(Modifier.height(14.dp))

            Box(Modifier.weight(1f)) {
                LazyVerticalGrid(
                    columns = GridCells.Fixed(2),
                    horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(10.dp),
                    verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(10.dp),
                ) {
                    // #1794：没有相册权限时相册区不给选，只说现状 + 申请入口；文件夹区照常。
                    if (!offersAlbums) {
                        item(key = "album-no-access", span = { GridItemSpan(maxLineSpan) }) {
                            AlbumNoAccessNotice(onRequest = onRequestAlbumAccess)
                        }
                    }
                    if (bucketScreenEmptyNoticeVisible(buckets.isEmpty(), folderBuckets.isEmpty(), albumAccess)) {
                        item(key = "empty", span = { GridItemSpan(maxLineSpan) }) {
                            Text(
                                stringResource(R.string.bucket_empty),
                                fontSize = 15.sp, color = PPColor.Ink40, textAlign = TextAlign.Center,
                                modifier = Modifier.fillMaxWidth().padding(top = 40.dp),
                            )
                        }
                    }
                    if (offersAlbums) {
                        items(buckets, key = { "album:${it.id}" }) { b ->
                            BucketCard(
                                bucket = b,
                                selected = b.id in checked,
                                isNew = b.id in newIds,
                                isFolder = false,
                                onToggle = { checked = if (b.id in checked) checked - b.id else checked + b.id },
                            )
                        }
                    }
                    items(folderBuckets, key = { "folder:${it.key}" }) { folder ->
                        BucketCard(
                            bucket = folder.bucket,
                            selected = folder.key in checkedFolders,
                            isNew = false,
                            isFolder = true,
                            actionLabel = stringResource(
                                if (folder.needsPermission) R.string.folder_reauthorize else R.string.folder_remove,
                            ),
                            onAction = {
                                if (folder.needsPermission) onReauthorizeFolder(folder.key) else removing = folder
                            },
                            secondaryActionLabel = if (folder.needsPermission) stringResource(R.string.folder_remove) else null,
                            onSecondaryAction = if (folder.needsPermission) { { removing = folder } } else null,
                            onToggle = {
                                checkedFolders = if (folder.key in checkedFolders) {
                                    checkedFolders - folder.key
                                } else {
                                    checkedFolders + folder.key
                                }
                            },
                        )
                    }
                    item(key = "add-folder") {
                        Column(
                            Modifier
                                .clip(RoundedCornerShape(16.dp))
                                .background(PPColor.ActBg)
                                .border(2.dp, PPColor.Border, RoundedCornerShape(16.dp))
                                .clickable(enabled = !saving, onClick = onAddFolder),
                        ) {
                            Box(
                                Modifier.fillMaxWidth().aspectRatio(1.6f),
                                contentAlignment = Alignment.Center,
                            ) {
                                Text("+", fontSize = 32.sp, fontWeight = FontWeight.Light, color = PPColor.Ink40)
                            }
                            Column(Modifier.height(72.dp).padding(12.dp, 9.dp, 12.dp, 11.dp)) {
                                Text(
                                    stringResource(R.string.folder_add),
                                    fontSize = 14.5.sp, fontWeight = FontWeight.SemiBold, color = PPColor.Ink,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                        }
                    }
                }
            }

            Spacer(Modifier.height(14.dp))
            Button(
                onClick = { onDone(checked, checkedFolders, time) },
                enabled = !saving,
                modifier = Modifier.fillMaxWidth().height(60.dp),
                shape = RoundedCornerShape(PPSize.RadiusControl),
                colors = ButtonDefaults.buttonColors(containerColor = PPColor.Ink, contentColor = PPColor.Paper),
            ) {
                Text(
                    stringResource(if (firstTime) R.string.bucket_start else R.string.bucket_save),
                    fontSize = 18.sp, fontWeight = FontWeight.Bold,
                )
            }
        }
        }
    }

    removing?.let { folder ->
        AlertDialog(
            onDismissRequest = { removing = null },
            title = { Text(stringResource(R.string.folder_remove_confirm_title, folder.bucket.name.orEmpty())) },
            text = { Text(stringResource(R.string.folder_remove_confirm_body)) },
            confirmButton = {
                TextButton(onClick = {
                    removing = null
                    onRemoveFolder(folder.key)
                    checkedFolders = checkedFolders - folder.key
                    seenFolderKeys = seenFolderKeys - folder.key
                }) { Text(stringResource(R.string.folder_remove_confirm_action), color = PPColor.Act) }
            },
            dismissButton = {
                TextButton(onClick = { removing = null }) {
                    Text(stringResource(R.string.folder_cancel), color = PPColor.Ink)
                }
            },
        )
    }
}
