// M5（全页面状态稿）：选相册——2 列封面卡片网格。#1797：相册卡、文件夹卡与
// 「添加文件夹」改用 #1796 的 Material 3 标准组件（SourceCard / AddSourceCard），
// 勾选、菜单与触控语义由组件承载，不再自绘角标、点击和描边；同一网格同一尺寸。
// 单个主按钮（取代旧的竖排复选框列表 + "取消/备份N个相册"两按钮）。共用入口：
// onboarding 配对成功后 与 设置页"备份哪些照片"重选，都是这一个 composable。
// #1263：标题「备份哪些照片」；相册之外加一行时间二选一（从今天起 / 全部）；删掉底部汇总句（每个相册有张数，
// Wi-Fi 条件在设置里）；按钮首次叫「开始备份」，编辑时叫「保存」，其余完全相同。不显示大小（iOS 没有公开接口，两端对齐）。
package com.hawkeyexb.ppass.ui

import android.content.ContentResolver
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.util.Size
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
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
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.backup.MediaAccess
import com.hawkeyexb.ppass.backup.MediaScanner
import com.hawkeyexb.ppass.backup.ScopeTime
import com.hawkeyexb.ppass.backup.newAlbumIds
import com.hawkeyexb.ppass.ui.components.AddSourceCard
import com.hawkeyexb.ppass.ui.components.SourceCard
import com.hawkeyexb.ppass.ui.components.SourceKind
import com.hawkeyexb.ppass.ui.components.SourceMenuAction
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

/** 「新」徽标——TriggerPolicy：编辑模式里刚出现、还没进过已保存范围的相册标「新」。
 *  它只是封面槽里的内容标记，不是选中控件；选中态由 SourceCard 的标准语义承载。 */
@Composable
private fun NewBadge(modifier: Modifier = Modifier) {
    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(6.dp),
        color = PPColor.Paper,
    ) {
        Text(
            stringResource(R.string.bucket_new),
            fontSize = 11.sp, fontWeight = FontWeight.Bold, color = PPColor.Waiting,
            modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
        )
    }
}

/** #1794：没有相册权限时相册区的现状说明 + 申请入口（样式同首页权限卡）。
 *  #1788：系统不再弹框时动作改「去设置」（对齐 iOS 同位置的 requestAccess / openAppSettings 分流），
 *  出口由调用方接应用详情页，设置回来按真实权限刷新。 */
@Composable
private fun AlbumNoAccessNotice(canPrompt: Boolean, onRequest: () -> Unit, onOpenSettings: () -> Unit) {
    val opensSettings = albumNoAccessNoticeOpensSettings(canPrompt)
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
                onClick = if (opensSettings) onOpenSettings else onRequest,
                modifier = Modifier.height(40.dp),
                shape = RoundedCornerShape(14.dp),
                border = androidx.compose.foundation.BorderStroke(1.dp, PPColor.Act.copy(alpha = 0.4f)),
                colors = ButtonDefaults.outlinedButtonColors(contentColor = PPColor.Act),
            ) {
                Text(
                    stringResource(if (opensSettings) R.string.auto_backup_blocked_action else R.string.scope_album_no_access_action),
                    fontSize = 15.sp, fontWeight = FontWeight.Bold,
                )
            }
        }
    }
}

/**
 * #1797：相册与文件夹共用的标准来源卡。勾选/点击/菜单语义由 SourceCard 承载，
 * 封面复用 BucketCoverImage；「新」徽标叠在封面槽内。卡片尺寸（封面高度、内容区）
 * 由 SourceCard 统一给出，相册、文件夹与「添加文件夹」天然同网格同尺寸。
 */
@Composable
private fun BucketSourceCard(
    title: String,
    bucketId: Long,
    coverUri: Uri?,
    count: Int,
    kind: SourceKind,
    kindLabel: String,
    selected: Boolean,
    isNew: Boolean = false,
    menuActions: List<SourceMenuAction> = emptyList(),
    onClick: () -> Unit,
) {
    SourceCard(
        title = title,
        countLabel = stringResource(R.string.bucket_count, count),
        kind = kind,
        kindLabel = kindLabel,
        selected = selected,
        selectedDescription = stringResource(R.string.source_selected),
        unselectedDescription = stringResource(R.string.source_unselected),
        onClick = onClick,
        cover = {
            BucketCoverImage(bucketId, coverUri, modifier = Modifier.fillMaxSize())
            if (isNew) {
                NewBadge(Modifier.align(Alignment.TopStart).padding(8.dp))
            }
        },
        menuActions = menuActions,
        menuContentDescription = stringResource(R.string.source_more_actions),
    )
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

/**
 * #1788：范围页相册提示的动作去向——系统还肯弹框（rationale=true）就页内申请；不再弹框
 * （问过至少一次后被锁，Android 官方口径：shouldShowRequestPermissionRationale）改「去设置」。
 * 对齐 iOS 同位置的 requestAccess / openAppSettings 分流；NONE 且 rationale=false 在本 App
 * 只可能是被锁——进范围页前 onboarding 的系统权限框一定先问过一次（同 `ruleEnableRoute` 部分态的口径）。
 */
internal fun albumNoAccessNoticeOpensSettings(canPrompt: Boolean): Boolean = !canPrompt

/** #1886：范围页两个时间胶囊放不下、需要换行——纯函数，单测用三星 SM-S928N 实测像素钉住。
 *
 *  输入是两段胶囊的**自身宽度**（含内边距，px）与行可用宽、间距；两段自身宽 + 间距超过可用宽就换行。
 *  这是两个胶囊容器（`FlowRow`）按内容换行的契约：不设宽度 / 字号 / 百分比阈值。旧写法（普通 `Row`）
 *  里第二个胶囊只吃第一个剩下的宽度，会被挤窄到装不下标签、底边把换行后的第二行裁掉。 */
internal fun scopeTimeChipsWrap(
    firstChipWidthPx: Int,
    secondChipWidthPx: Int,
    gapPx: Int,
    availableWidthPx: Int,
): Boolean = firstChipWidthPx + gapPx + secondChipWidthPx > availableWidthPx

data class FolderBucketUi(
    val key: String,
    val bucket: MediaScanner.Bucket,
    val registered: Boolean,
    val needsPermission: Boolean = false,
)

@OptIn(ExperimentalLayoutApi::class)
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
    /** #1788：系统还肯不肯为相册权限弹框（rationale）；false = 被锁，页内动作改「去设置」。 */
    albumAccessCanPrompt: Boolean = true,
    onRequestAlbumAccess: () -> Unit = {},
    onOpenAlbumSettings: () -> Unit = {},
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
                // #1797：返回交给 Material3 IconButton——触控区、涟漪、role 与描述由组件给出，与 FolderScreen 同款。
                IconButton(onClick = onCancel) {
                    Icon(
                        imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                        contentDescription = stringResource(R.string.back),
                        tint = PPColor.Ink,
                    )
                }
                // #1801：页标题标 heading 语义，TalkBack 按标题导航直达本页；不改视觉。
                Text(
                    stringResource(R.string.backup_scope),
                    fontSize = 24.sp, fontFamily = PPFont.Serif, color = PPColor.Ink,
                    modifier = Modifier.semantics { heading() },
                )
            }
            Spacer(Modifier.height(12.dp))
            // #1886：两个时间胶囊改放可换行的 FlowRow——普通 Row 里第二个胶囊只能吃第一个剩下的宽度，
            // 英文 1.5× 时被挤成 145px（51.5dp），标签被硬裁成「Incl」。FlowRow 放不下时把第二个胶囊
            // 整体落到下一行、各自保持自身宽度，不再互相挤；换行契约见 scopeTimeChipsWrap（纯函数，单测钉住）。
            FlowRow(
                horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(8.dp),
                verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(8.dp),
            ) {
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
                            AlbumNoAccessNotice(
                                canPrompt = albumAccessCanPrompt,
                                onRequest = onRequestAlbumAccess,
                                onOpenSettings = onOpenAlbumSettings,
                            )
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
                            BucketSourceCard(
                                title = b.name ?: stringResource(R.string.bucket_unnamed),
                                bucketId = b.id,
                                coverUri = b.coverUri,
                                count = b.count,
                                kind = SourceKind.ALBUM,
                                kindLabel = stringResource(R.string.source_kind_album),
                                selected = b.id in checked,
                                isNew = b.id in newIds,
                                onClick = {
                                    checked = if (b.id in checked) checked - b.id else checked + b.id
                                },
                            )
                        }
                    }
                    items(folderBuckets, key = { "folder:${it.key}" }) { folder ->
                        // #1797：重新授权与移除收进标准菜单；移除仍先过确认弹窗（语义不变）。
                        BucketSourceCard(
                            title = folder.bucket.name ?: stringResource(R.string.bucket_unnamed),
                            bucketId = folder.bucket.id,
                            coverUri = folder.bucket.coverUri,
                            count = folder.bucket.count,
                            kind = SourceKind.FOLDER,
                            kindLabel = stringResource(R.string.source_kind_folder),
                            selected = folder.key in checkedFolders,
                            menuActions = buildList {
                                if (folder.needsPermission) {
                                    add(SourceMenuAction(stringResource(R.string.folder_reauthorize)) { onReauthorizeFolder(folder.key) })
                                }
                                add(SourceMenuAction(stringResource(R.string.folder_remove)) { removing = folder })
                            },
                            onClick = {
                                checkedFolders = if (folder.key in checkedFolders) {
                                    checkedFolders - folder.key
                                } else {
                                    checkedFolders + folder.key
                                }
                            },
                        )
                    }
                    item(key = "add-folder") {
                        AddSourceCard(
                            label = stringResource(R.string.folder_add),
                            actionContentDescription = stringResource(R.string.folder_add),
                            onClick = { if (!saving) onAddFolder() },
                        )
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
