// MOB-115: 原片（视频）长期缓存的命中判据。
//
// 旧判据 `isFile && length() > 0` 让断流留下的截断文件永久命中。新判据：
// 文件长度必须等于 asset 元数据里的 bytes（来源：timeline 的 AssetMeta.bytes
// ← daemon query.rs 的 asset.bytes ← 入库时的文件大小）。不符、或期望长度
// 未知（<= 0，无从校验）就删掉重下——升级前留下的坏缓存也由此清掉。
//
// 命中时只校长度、不重算 BLAKE3：每次打开都读一遍整文件的代价与文件大小
// 成正比；新写入的缓存在下载时已校验过 BLAKE3 才落盘（VerifiedDownload.kt），
// 而旧逻辑唯一的坏法是截断，长度足以识别。
package com.hawkeyexb.ppass.ui

import java.io.File

/** [file] 是否是一份完整的缓存；不是则删掉（含同名 `.part` 残留）并返回 false。 */
internal fun isCompleteOriginal(file: File, expectedBytes: Long): Boolean {
    if (expectedBytes > 0 && file.isFile && file.length() == expectedBytes) return true
    file.delete()
    File(file.absoluteFile.parentFile, file.name + ".part").delete()
    return false
}

/**
 * 命中完整缓存直接返回；否则删掉坏文件，经 [download] 重新取到 [file]。
 * [download] 失败时异常原样上抛（下载层保证失败不留下 [file]）。
 */
internal suspend fun fetchOriginalCached(
    file: File,
    expectedBytes: Long,
    download: suspend (File) -> Unit,
): File {
    if (isCompleteOriginal(file, expectedBytes)) return file
    download(file)
    return file
}
