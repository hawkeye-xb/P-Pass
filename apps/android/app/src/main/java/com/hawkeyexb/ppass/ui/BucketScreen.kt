package com.hawkeyexb.ppass.ui

import android.graphics.Bitmap
import android.net.Uri
import android.util.Size
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.backup.MediaAccess
import com.hawkeyexb.ppass.backup.MediaScanner
import com.hawkeyexb.ppass.backup.ScopeTime
import com.hawkeyexb.ppass.backup.decodeBucketCover
import com.hawkeyexb.ppass.backup.newAlbumIds
import com.hawkeyexb.ppass.ui.components.SourceCard
import com.hawkeyexb.ppass.ui.components.SourceKind
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

private fun bucketCoverCacheKey(bucketId: Long, displaySize: IntSize) =
    "bucket:$bucketId:${displaySize.width}x${displaySize.height}"

@Composable
private fun BucketCoverImage(bucketId: Long, coverUri: Uri?, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    var displaySize by remember { mutableStateOf(IntSize.Zero) }
    val cacheKey = bucketCoverCacheKey(bucketId, displaySize)
    @Suppress("ProduceStateDoesNotAssignValue")
    val bmp by produceState(
        initialValue = thumbCache.get(cacheKey),
        key1 = coverUri,
        key2 = displaySize,
    ) {
        if (value == null && coverUri != null && displaySize != IntSize.Zero) {
            value = withContext(Dispatchers.IO) {
                decodeBucketCover(context, coverUri, Size(displaySize.width, displaySize.height))
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

/** 没有相册权限时相册区的现状说明 + 申请入口（样式同首页权限卡）。
 *  系统不再弹框时动作改「去设置」（对齐 iOS 同位置的 requestAccess / openAppSettings 分流），
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
                stringResource(R.string.scope_album_no_access_title),
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
                border = BorderStroke(1.dp, PPColor.Act.copy(alpha = 0.4f)),
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

/** 相册网格卡片：走标准 SourceCard，封面复用 BucketCoverImage，「新」徽标叠在封面槽内。 */
@Composable
private fun BucketAlbumCard(
    title: String,
    bucketId: Long,
    coverUri: Uri?,
    count: Int,
    selected: Boolean,
    isNew: Boolean,
    onClick: () -> Unit,
) {
    SourceCard(
        title = title,
        countLabel = stringResource(R.string.bucket_count, count),
        kind = SourceKind.ALBUM,
        kindLabel = stringResource(R.string.source_kind_album),
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
    )
}

/** 紧凑文件夹列表行（放相册网格下方）：用 Material3 ListItem 传达「立即管理 vs 点保存生效」的区分；
 *  整行 toggleable 负责勾选（点底部保存生效），失效行显性标出「需要重新允许」与直达重授按钮，菜单收移除确认。 */
@Composable
private fun BucketFolderRow(
    folder: FolderBucketUi,
    selected: Boolean,
    enabled: Boolean,
    onToggle: (Boolean) -> Unit,
    onReauthorize: () -> Unit,
    onRequestRemove: () -> Unit,
) {
    val stateDesc = stringResource(if (selected) R.string.source_selected else R.string.source_unselected)
    var menuExpanded by remember { mutableStateOf(false) }

    ListItem(
        modifier = Modifier
            .fillMaxWidth()
            .toggleable(
                value = selected,
                enabled = enabled,
                role = Role.Checkbox,
                onValueChange = onToggle,
            )
            .semantics { stateDescription = stateDesc },
        leadingContent = {
            Checkbox(
                checked = selected,
                onCheckedChange = null,
                enabled = enabled,
                colors = CheckboxDefaults.colors(
                    checkedColor = PPColor.Ink,
                    checkmarkColor = PPColor.Paper,
                    uncheckedColor = PPColor.BorderStrong,
                ),
            )
        },
        headlineContent = {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Icon(
                    painter = painterResource(R.drawable.ic_folder),
                    contentDescription = stringResource(R.string.source_kind_folder),
                    modifier = Modifier.size(16.dp),
                    tint = if (folder.needsPermission) PPColor.Act else PPColor.Ink60,
                )
                Text(
                    text = folder.bucket.name ?: stringResource(R.string.bucket_unnamed),
                    style = MaterialTheme.typography.titleMedium,
                    color = PPColor.Ink,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        },
        supportingContent = {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                if (folder.needsPermission) {
                    Text(
                        text = stringResource(R.string.folder_status_needs_permission),
                        style = MaterialTheme.typography.labelMedium,
                        color = PPColor.Act,
                    )
                    OutlinedButton(
                        onClick = onReauthorize,
                        enabled = enabled,
                        shape = RoundedCornerShape(12.dp),
                        border = BorderStroke(1.dp, PPColor.Act.copy(alpha = 0.45f)),
                        colors = ButtonDefaults.outlinedButtonColors(
                            containerColor = PPColor.ActBg,
                            contentColor = PPColor.Act,
                        ),
                        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp),
                        modifier = Modifier.heightIn(min = 36.dp),
                    ) {
                        Text(
                            text = stringResource(R.string.folder_reauthorize),
                            style = MaterialTheme.typography.labelLarge,
                            fontWeight = FontWeight.Bold,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                } else {
                    Text(
                        text = stringResource(R.string.bucket_count, folder.bucket.count),
                        style = MaterialTheme.typography.labelMedium,
                        color = PPColor.Ink40,
                    )
                }
            }
        },
        trailingContent = {
            Box {
                IconButton(
                    onClick = { menuExpanded = true },
                    enabled = enabled,
                    modifier = Modifier.size(PPSize.TapMin),
                ) {
                    Icon(
                        imageVector = Icons.Default.MoreVert,
                        contentDescription = stringResource(R.string.source_more_actions),
                        tint = PPColor.Ink60,
                    )
                }
                DropdownMenu(expanded = menuExpanded, onDismissRequest = { menuExpanded = false }) {
                    if (folder.needsPermission) {
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.folder_reauthorize)) },
                            onClick = {
                                menuExpanded = false
                                onReauthorize()
                            },
                        )
                    }
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.folder_remove)) },
                        onClick = {
                            menuExpanded = false
                            onRequestRemove()
                        },
                    )
                }
            }
        },
        colors = ListItemDefaults.colors(
            containerColor = Color.Transparent,
            headlineColor = PPColor.Ink,
            supportingColor = PPColor.Ink40,
        ),
    )
}

/**
 * 相册区能不能选。相册自动备份只认完整照片权限——「部分照片权限」对相册自动备份
 * 与「无权限」没有区别（底层引擎和首页 HeroCard 在 PARTIAL 下都停止相册自动备份），所以只有 FULL
 * 才给选相册；PARTIAL / NONE 都在顶部显示现状与开启入口。
 * 文件夹区与顶栏目录入口不受影响（对齐 iOS，范围页始终能进）。
 */
internal fun bucketScreenOffersAlbumChoices(access: MediaAccess): Boolean = access == MediaAccess.FULL

internal fun bucketScreenAccessNoticeKey(access: MediaAccess): String? =
    if (bucketScreenOffersAlbumChoices(access)) null else "scope_album_no_access_title"

/**
 * 相册卡片显示哪些（对齐 iOS `BucketScreen.visibleAlbums` 的不变量）。
 * 完整授权显示全部；未完整授权只显示当前编辑态里勾着的相册（已保存的 + 本次未保存勾选的），
 * 保证它们仍能取消；没勾的受限相册不展示，避免诱使用户误选一勾就报「自动备份已停止」。
 */
internal fun visibleAlbumBuckets(
    buckets: List<MediaScanner.Bucket>,
    checked: Set<Long>,
    access: MediaAccess,
): List<MediaScanner.Bucket> =
    if (bucketScreenOffersAlbumChoices(access)) buckets else buckets.filter { it.id in checked }

/**
 * 整机空文案（「手机上没有照片或视频」）只在真读得到完整照片权限、且相册与文件夹都为空时成立；
 * 没有完整权限（含部分权限）时读不到全部照片，不能说成整机没有照片。
 */
internal fun bucketScreenEmptyNoticeVisible(
    bucketsEmpty: Boolean,
    foldersEmpty: Boolean,
    access: MediaAccess,
): Boolean = bucketsEmpty && foldersEmpty && bucketScreenOffersAlbumChoices(access)

/** 文件夹分组仅在已有文件夹时按需出现；从未添加过时完全不占版面。 */
internal fun bucketScreenShowsFoldersSection(folderBuckets: List<FolderBucketUi>): Boolean =
    folderBuckets.isNotEmpty()

internal fun visibleSelectedAlbumCount(
    buckets: List<MediaScanner.Bucket>,
    checked: Set<Long>,
    access: MediaAccess,
): Int = visibleAlbumBuckets(buckets, checked, access).count { it.id in checked }

internal fun selectedFolderCount(
    folderBuckets: List<FolderBucketUi>,
    checkedFolders: Set<String>,
): Int = folderBuckets.count { it.key in checkedFolders }

internal fun formatBucketActionLabel(
    baseLabel: String,
    albumPart: String?,
    folderPart: String?,
    formatWithSummary: (String, String) -> String,
    formatEmpty: (String) -> String,
): String {
    val summary = listOfNotNull(albumPart, folderPart).joinToString(" · ")
    return if (summary.isEmpty()) formatEmpty(baseLabel) else formatWithSummary(baseLabel, summary)
}

/**
 * 范围页相册提示的动作去向——系统还肯弹框（rationale=true）就页内申请；不再弹框
 * （问过至少一次后被锁，Android 官方口径：shouldShowRequestPermissionRationale）改「去设置」。
 * 对齐 iOS 同位置的 requestAccess / openAppSettings 分流；NONE 且 rationale=false 在本 App
 * 只可能是被锁——进范围页前 onboarding 的系统权限框一定先问过一次（同 `ruleEnableRoute` 部分态的口径）。
 */
internal fun albumNoAccessNoticeOpensSettings(canPrompt: Boolean): Boolean = !canPrompt

data class FolderBucketUi(
    val key: String,
    val bucket: MediaScanner.Bucket,
    val registered: Boolean,
    val needsPermission: Boolean = false,
)

@OptIn(ExperimentalMaterial3Api::class)
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
    /** 系统还肯不肯为相册权限弹框（rationale）；false = 被锁，页内动作改「去设置」。 */
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
    val visibleAlbums = visibleAlbumBuckets(buckets, checked, albumAccess)
    val showFoldersSection = bucketScreenShowsFoldersSection(folderBuckets)

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
        Scaffold(
            modifier = Modifier.fillMaxSize(),
            containerColor = PPColor.Paper,
            topBar = {
                TopAppBar(
                    title = {
                        Text(
                            stringResource(R.string.backup_scope),
                            style = MaterialTheme.typography.headlineSmall.copy(fontFamily = PPFont.Serif),
                            color = PPColor.Ink,
                            modifier = Modifier.semantics { heading() },
                        )
                    },
                    navigationIcon = {
                        IconButton(onClick = onCancel) {
                            Icon(
                                imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                                contentDescription = stringResource(R.string.back),
                                tint = PPColor.Ink,
                            )
                        }
                    },
                    actions = {
                        IconButton(onClick = onAddFolder, enabled = !saving) {
                            Icon(
                                painter = painterResource(R.drawable.ic_create_new_folder),
                                contentDescription = stringResource(R.string.folder_add),
                                tint = if (!saving) PPColor.Ink else PPColor.Ink40,
                            )
                        }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(
                        containerColor = PPColor.Paper,
                        scrolledContainerColor = PPColor.Paper,
                        navigationIconContentColor = PPColor.Ink,
                        titleContentColor = PPColor.Ink,
                    ),
                )
            },
        ) { innerPadding ->
        Column(Modifier.fillMaxSize().padding(innerPadding).padding(horizontal = 24.dp, vertical = 16.dp)) {
            Text(
                text = stringResource(R.string.scope_time_section),
                style = MaterialTheme.typography.labelMedium,
                color = PPColor.Ink60,
                modifier = Modifier.semantics { heading() },
            )
            Spacer(Modifier.height(8.dp))
            // 原生 M3 分段控件与照片页筛选胶囊彻底区分；IntrinsicSize.Min + fillMaxHeight 让两段在大字号
            // 换行时同步长高、不裁字不重叠；zIndex(1f) 与下方 Box.clipToBounds() 防止滚动卡片触控框外溢遮挡。
            SingleChoiceSegmentedButtonRow(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(IntrinsicSize.Min)
                    .zIndex(1f),
            ) {
                val segmentColors = SegmentedButtonDefaults.colors(
                    activeContainerColor = PPColor.Ink,
                    activeContentColor = PPColor.Paper,
                    activeBorderColor = PPColor.Ink,
                    inactiveContainerColor = PPColor.Linen,
                    inactiveContentColor = PPColor.Ink60,
                    inactiveBorderColor = PPColor.BorderStrong,
                )
                SegmentedButton(
                    selected = time == ScopeTime.SINCE_TODAY,
                    onClick = { time = ScopeTime.SINCE_TODAY },
                    shape = SegmentedButtonDefaults.itemShape(index = 0, count = 2),
                    modifier = Modifier.fillMaxHeight().heightIn(min = 48.dp),
                    colors = segmentColors,
                    icon = {},
                    label = {
                        Text(
                            text = sinceLabel,
                            style = MaterialTheme.typography.labelLarge,
                            textAlign = TextAlign.Center,
                            maxLines = 2,
                            softWrap = true,
                        )
                    },
                )
                SegmentedButton(
                    selected = time == ScopeTime.ALL,
                    onClick = { time = ScopeTime.ALL },
                    shape = SegmentedButtonDefaults.itemShape(index = 1, count = 2),
                    modifier = Modifier.fillMaxHeight().heightIn(min = 48.dp),
                    colors = segmentColors,
                    icon = {},
                    label = {
                        Text(
                            text = stringResource(R.string.scope_time_all),
                            style = MaterialTheme.typography.labelLarge,
                            textAlign = TextAlign.Center,
                            maxLines = 2,
                            softWrap = true,
                        )
                    },
                )
            }
            Spacer(Modifier.height(14.dp))

            Box(Modifier.weight(1f).clipToBounds()) {
                LazyVerticalGrid(
                    columns = GridCells.Fixed(2),
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    // 没有完整相册权限时相册区不给新增选择，只说现状 + 申请入口；文件夹区照常。
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
                    // 未完整授权时只剩编辑态里勾着的相册（可取消），不显示诱选受限相册。
                    items(visibleAlbums, key = { "album:${it.id}" }) { b ->
                        BucketAlbumCard(
                            title = b.name ?: stringResource(R.string.bucket_unnamed),
                            bucketId = b.id,
                            coverUri = b.coverUri,
                            count = b.count,
                            selected = b.id in checked,
                            isNew = b.id in newIds,
                            onClick = {
                                checked = if (b.id in checked) checked - b.id else checked + b.id
                            },
                        )
                    }
                    if (showFoldersSection) {
                        item(key = "folders-header", span = { GridItemSpan(maxLineSpan) }) {
                            Text(
                                text = stringResource(R.string.scope_folders_section),
                                style = MaterialTheme.typography.labelMedium,
                                color = PPColor.Ink60,
                                modifier = Modifier
                                    .padding(top = if (visibleAlbums.isEmpty() && offersAlbums) 0.dp else 10.dp)
                                    .semantics { heading() },
                            )
                        }
                        item(key = "folders-group", span = { GridItemSpan(maxLineSpan) }) {
                            Surface(
                                color = PPColor.Paper,
                                shape = RoundedCornerShape(PPSize.RadiusCard),
                                border = BorderStroke(1.dp, PPColor.Border),
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                Column {
                                    folderBuckets.forEachIndexed { index, folder ->
                                        if (index > 0) {
                                            HorizontalDivider(color = PPColor.Divider)
                                        }
                                        BucketFolderRow(
                                            folder = folder,
                                            selected = folder.key in checkedFolders,
                                            enabled = !saving,
                                            onToggle = { isChecked ->
                                                checkedFolders = if (isChecked) {
                                                    checkedFolders + folder.key
                                                } else {
                                                    checkedFolders - folder.key
                                                }
                                            },
                                            onReauthorize = { onReauthorizeFolder(folder.key) },
                                            onRequestRemove = { removing = folder },
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Spacer(Modifier.height(14.dp))
            val selectedAlbumsCount = visibleSelectedAlbumCount(buckets, checked, albumAccess)
            val selectedFoldersCount = selectedFolderCount(folderBuckets, checkedFolders)
            val baseAction = stringResource(if (firstTime) R.string.bucket_start else R.string.bucket_save)
            val albumPart = if (selectedAlbumsCount > 0) {
                pluralStringResource(R.plurals.backup_scope_n, selectedAlbumsCount, selectedAlbumsCount)
            } else {
                null
            }
            val folderPart = if (selectedFoldersCount > 0) {
                pluralStringResource(R.plurals.backup_scope_folder_n, selectedFoldersCount, selectedFoldersCount)
            } else {
                null
            }
            val summary = listOfNotNull(albumPart, folderPart).joinToString(" · ")
            val actionText = if (summary.isEmpty()) {
                stringResource(R.string.bucket_action_empty, baseAction)
            } else {
                stringResource(R.string.bucket_action_with_summary, baseAction, summary)
            }
            Button(
                onClick = { onDone(checked, checkedFolders, time) },
                enabled = !saving,
                modifier = Modifier.fillMaxWidth().heightIn(min = 60.dp),
                shape = RoundedCornerShape(PPSize.RadiusControl),
                colors = ButtonDefaults.buttonColors(containerColor = PPColor.Ink, contentColor = PPColor.Paper),
            ) {
                Text(
                    text = actionText,
                    fontSize = 18.sp,
                    fontWeight = FontWeight.Bold,
                    textAlign = TextAlign.Center,
                )
            }
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
