// T6 (H-10b): 相册选择——"选择备份内容"与"发起备份"是两个动作。
// 列出 MediaStore 相册（名称+张数），勾选要备份的，微信/QQ 等相册
// 可以不勾（微信自带备份，无需独立备份它收到的图）。
package com.hawkeyexb.ppass.ui

import android.content.ContentResolver
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.OutlinedButton
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
        resolver.loadThumbnail(uri, android.util.Size(96, 96), null)
    } else {
        null
    }
}.getOrNull()

@Composable
private fun BucketCover(bucketId: Long, coverUri: Uri?) {
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
    Box(
        Modifier.size(48.dp).clip(RoundedCornerShape(10.dp)).background(PPColor.Linen),
        contentAlignment = Alignment.Center,
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
    var selectAll by remember { mutableStateOf(selected.size == buckets.size) }
    // MOB-02 §六: 新出现的相册 = 当前 − 已知；标「新」徽标，默认不勾选
    // （不在 selected 里）——配合用户「专用目录」用法。
    val newIds = newAlbumIds(buckets.map { it.id }.toSet(), knownBuckets)

    PPScreen {
        Column(
            Modifier.fillMaxSize().padding(24.dp),
        ) {
        Text(
            stringResource(R.string.bucket_title),
            fontSize = 28.sp, fontFamily = FontFamily.Serif, color = PPColor.Ink,
        )
        Spacer(Modifier.height(8.dp))
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
                LazyColumn {
                    items(buckets, key = { it.id }) { b ->
                        val on = b.id in checked
                        Row(
                            Modifier.fillMaxWidth()
                                .clickable {
                                    checked = if (on) checked - b.id else checked + b.id
                                }
                                .padding(vertical = 10.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            // UX-10: 封面缩略图——像普通图库相册选择器那样，
                            // 一眼认出相册是什么，不用光靠名字猜。
                            BucketCover(b.id, b.coverUri)
                            Spacer(Modifier.width(12.dp))
                            Checkbox(
                                checked = on,
                                onCheckedChange = { c ->
                                    checked = if (c) checked + b.id else checked - b.id
                                },
                                colors = CheckboxDefaults.colors(
                                    checkedColor = PPColor.Safe,
                                    uncheckedColor = PPColor.Ink40,
                                ),
                            )
                            Text(
                                b.name,
                                fontSize = 16.sp, color = PPColor.Ink,
                                modifier = Modifier.weight(1f),
                            )
                            // MOB-02 §六: 新相册徽标（琥珀小标，不抢主内容）。
                            if (b.id in newIds) {
                                Text(
                                    stringResource(R.string.bucket_new),
                                    fontSize = 11.sp, fontWeight = FontWeight.Bold,
                                    color = PPColor.Waiting,
                                    modifier = Modifier.padding(start = 6.dp),
                                )
                            }
                            Text(
                                stringResource(R.string.bucket_count, b.count),
                                fontSize = 14.sp, color = PPColor.Ink40,
                            )
                        }
                    }
                }
            }
        }

        Spacer(Modifier.height(12.dp))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            OutlinedButton(
                onClick = {
                    selectAll = !selectAll
                    checked = if (selectAll) buckets.map { it.id }.toSet() else emptySet()
                },
                modifier = Modifier.weight(1f).height(52.dp),
                shape = RoundedCornerShape(PPSize.RadiusControl),
            ) {
                Text(
                    stringResource(if (selectAll) R.string.bucket_clear else R.string.bucket_select_all),
                    fontSize = 15.sp, color = PPColor.Ink,
                )
            }
            OutlinedButton(
                onClick = onCancel,
                modifier = Modifier.weight(1f).height(52.dp),
                shape = RoundedCornerShape(PPSize.RadiusControl),
            ) { Text(stringResource(R.string.cancel), fontSize = 15.sp, color = PPColor.Ink) }
        }
        Spacer(Modifier.height(10.dp))
        OutlinedButton(
            onClick = { onDone(checked) },
            modifier = Modifier.fillMaxWidth().height(58.dp),
            shape = RoundedCornerShape(PPSize.RadiusControl),
        ) {
            Text(
                stringResource(R.string.bucket_done, checked.size),
                fontSize = 17.sp, color = PPColor.Safe, fontWeight = FontWeight.Bold,
            )
        }
        Spacer(Modifier.height(6.dp))
        }
    }
}
