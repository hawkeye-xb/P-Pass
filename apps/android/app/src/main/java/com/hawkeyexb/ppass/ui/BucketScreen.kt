// M5（全页面状态稿）：选相册——2 列封面卡片网格，右上角圆形勾选角标，
// 顶部总结句+单个"开始备份"主按钮（取代旧的竖排复选框列表 +
// "取消/备份N个相册"两按钮）。共用入口：onboarding 配对成功后 与
// 设置页"备份哪些相册"重选，都是这一个 composable。
package com.hawkeyexb.ppass.ui

import android.content.ContentResolver
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import androidx.compose.foundation.Image
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
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.backup.MediaScanner
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
private fun bucketCoverCacheKey(bucketId: Long) = "bucket:$bucketId"

/** API 29+ 用官方 loadThumbnail（图片/视频统一接口）；更早的 API 让
 *  封面留空——这是纯视觉锚点，不是必需功能，不为老设备多维护一条
 *  解码路径。 */
private fun decodeBucketCover(resolver: ContentResolver, uri: Uri): Bitmap? = runCatching {
    if (Build.VERSION.SDK_INT >= 29) {
        resolver.loadThumbnail(uri, android.util.Size(200, 200), null)
    } else {
        null
    }
}.getOrNull()

@Composable
private fun BucketCoverImage(bucketId: Long, coverUri: Uri?, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val cacheKey = bucketCoverCacheKey(bucketId)
    val bmp by produceState(
        initialValue = thumbCache.get(cacheKey),
        key1 = coverUri,
    ) {
        if (value == null && coverUri != null) {
            value = withContext(Dispatchers.IO) {
                runCatching { decodeBucketCover(context.contentResolver, coverUri) }.getOrNull()
            }?.also { thumbCache.put(cacheKey, it) }
        }
    }
    Box(modifier.background(PPColor.Linen)) {
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
private fun BucketCard(
    bucket: MediaScanner.Bucket,
    selected: Boolean,
    isNew: Boolean,
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
        Column(Modifier.padding(12.dp, 9.dp, 12.dp, 11.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    bucket.name, fontSize = 14.5.sp, fontWeight = FontWeight.SemiBold,
                    color = PPColor.Ink, modifier = Modifier.weight(1f, fill = false),
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
            Text(
                stringResource(R.string.bucket_count, bucket.count),
                fontSize = 12.5.sp, color = PPColor.Ink40,
            )
        }
    }
}

@Composable
fun BucketScreen(
    buckets: List<MediaScanner.Bucket>,
    selected: Set<Long>,
    // MOB-02 §六: 新相册判定基准（null = 从未选过范围 = 全量模式，无徽标）。
    knownBuckets: Set<Long>? = null,
    onDone: (Set<Long>) -> Unit,
    onCancel: () -> Unit,
) {
    var checked by remember { mutableStateOf(selected) }
    // MOB-02 §六: 新出现的相册 = 当前 − 已知；标「新」徽标，默认不勾选
    // （不在 selected 里）——配合用户「专用目录」用法。
    val newIds = newAlbumIds(buckets.map { it.id }.toSet(), knownBuckets)
    val selectedCount = buckets.filter { it.id in checked }.sumOf { it.count }

    PPScreen {
        Column(Modifier.fillMaxSize().padding(24.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "‹", fontSize = 24.sp, color = PPColor.Ink,
                    modifier = Modifier.clickable(onClick = onCancel).padding(4.dp, 0.dp, 10.dp, 0.dp),
                )
                Column {
                    Text(
                        stringResource(R.string.bucket_title),
                        fontSize = 24.sp, fontFamily = FontFamily.Serif, color = PPColor.Ink,
                    )
                }
            }
            Spacer(Modifier.height(6.dp))
            Text(
                stringResource(R.string.bucket_hint),
                fontSize = 14.sp, lineHeight = 21.sp, color = PPColor.Ink40,
            )
            Spacer(Modifier.height(16.dp))

            Box(Modifier.weight(1f)) {
                if (buckets.isEmpty()) {
                    Text(
                        stringResource(R.string.bucket_empty),
                        fontSize = 15.sp, color = PPColor.Ink40,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth().padding(top = 40.dp),
                    )
                } else {
                    LazyVerticalGrid(
                        columns = GridCells.Fixed(2),
                        horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(10.dp),
                        verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(10.dp),
                    ) {
                        items(buckets, key = { it.id }) { b ->
                            BucketCard(
                                bucket = b,
                                selected = b.id in checked,
                                isNew = b.id in newIds,
                                onToggle = {
                                    checked = if (b.id in checked) checked - b.id else checked + b.id
                                },
                            )
                        }
                    }
                }
            }

            Spacer(Modifier.height(14.dp))
            Text(
                stringResource(R.string.bucket_summary, groupThousands(selectedCount.toLong())),
                fontSize = 13.5.sp, lineHeight = 20.sp, color = PPColor.Ink60,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(10.dp))
            Button(
                onClick = { onDone(checked) },
                modifier = Modifier.fillMaxWidth().height(60.dp),
                shape = RoundedCornerShape(PPSize.RadiusControl),
                colors = ButtonDefaults.buttonColors(
                    containerColor = PPColor.Ink, contentColor = PPColor.Paper
                ),
            ) {
                Text(
                    stringResource(R.string.bucket_start),
                    fontSize = 18.sp, fontWeight = FontWeight.Bold,
                )
            }
        }
    }
}
