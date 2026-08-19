// MOB-09 验收：MediaStore 里「有行、没实体文件」的记录不许炸掉整批备份。
//
// 现场（2026-08-18 真机）：5 条 _size=NULL 的空记录让每一轮自动备份都是
//   W PPassBackup: auto backup failed, will retry
//   W PPassBackup: java.io.FileNotFoundException: open failed: ENOENT
//       at BackupWorker.doWork$lambda$0$0 → hashWithCache → doWork
// 整批记失败走重试，重试再撞同一条，watermark 不推进——一条坏记录永久
// 卡死这台设备的所有后续备份。删掉那 5 条后同一批立刻跑通
// （auto backup: offered=15 pushed=15 ingested=14）。
//
// 测的是生产函数 buildCandidates（doWork 的候选构建就是调它，见
// wiring 测试），build lambda 与 doWork 里那段同形：探针 open + PERF-01
// 的 hashWithCache。offered 的定义就是 manifest.hashes.size ==
// candidates.size（BackupRunner.run），所以「正常候选全部进入 offered」
// 在 JVM 侧等价于「正常候选全部出现在 candidates 里」——真正带 offered
// 数字的那一步要活 daemon / 真机，走卡面的真机验收。
//
// 反证（卡面必带）：把 buildCandidates 里的 catch 去掉（改成无条件
// rethrow）→ 本文件前四个测试必须变红。
package com.hawkeyexb.ppass.backup

import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileNotFoundException
import java.io.InputStream
import kotlin.coroutines.cancellation.CancellationException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class BadMediaRecordTest {

    /** 源码级断言的公共前处理：**剥掉注释行**（TriggerPolicyTest 同款，
     *  这里连 KDoc/块注释行一起剥）。
     *
     *  正向：直接 contains 会被「把那行代码注释掉」骗过去，是假绿。
     *  反向（本卡实测踩到）：`!src.contains(...)` 这种禁令断言会被**注释里
     *  引用的旧写法**误判成红——buildCandidates 的 KDoc 里写了旧实现长什么
     *  样，禁令就炸了。两个方向都只有先剥注释才成立。 */
    private fun codeOf(file: File): String =
        file.readText().lines()
            .filterNot {
                val t = it.trimStart()
                t.startsWith("//") || t.startsWith("*") || t.startsWith("/*")
            }
            .joinToString("\n")

    private fun repoRoot(): File {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        return dir
    }

    private fun tempDir(tag: String): File =
        java.nio.file.Files.createTempDirectory("ppass-badmedia-$tag").toFile()

    /** 一条 MediaStore 记录。[content] == null = 有行、没实体文件：
     *  open 抛 FileNotFoundException，与真机 ENOENT 同型。 */
    private class Record(val name: String, val content: ByteArray?) {
        var opens = 0
        fun open(): InputStream {
            opens++
            return content?.let { ByteArrayInputStream(it) }
                ?: throw FileNotFoundException(
                    "open failed: ENOENT (No such file or directory)"
                )
        }
    }

    private fun good(i: Int) = Record("IMG_$i.jpg", ByteArray(1024) { (it + i).toByte() })
    private fun bad(i: Int) = Record("BAD_$i.jpg", null)

    /** 与 doWork 候选构建同形的 build lambda：探针 open + hashWithCache。 */
    private fun buildOf(cache: HashCache): (Record) -> Candidate = { rec ->
        val open = rec::open
        open().use { }
        val key = hashCacheKey(
            "content://media/external/images/media/${rec.name}",
            generation = 7L,
            dateModified = 1000L,
            bytes = (rec.content?.size ?: 0).toLong(),
            api30Plus = true,
        )
        val hash = hashWithCache(cache, key, open)
        Candidate(
            hash = hash,
            fileName = rec.name,
            mediaType = "image/jpeg",
            bytes = (rec.content?.size ?: 0).toLong(),
            open = open,
        )
    }

    @Test
    fun one_unreadable_record_does_not_kill_the_batch() {
        // 卡面验收：一个 open 抛 FileNotFoundException 的候选 + 若干正常
        // 候选 → 正常候选全部进入 offered，坏候选被跳过，整体不抛异常。
        val dir = tempDir("one-bad")
        val cache = HashCache(File(dir, "hash-cache.json"))
        val records = listOf(good(1), good(2), bad(1), good(3))

        val built = buildCandidates(records, buildOf(cache))

        assertEquals(
            "正常候选必须全部进入 offered（= manifest.hashes = candidates）",
            listOf("IMG_1.jpg", "IMG_2.jpg", "IMG_3.jpg"),
            built.candidates.map { it.fileName },
        )
        assertEquals(
            "坏候选必须被跳过并被记下（不能静默吞）",
            listOf("BAD_1.jpg"),
            built.skipped.map { it.name },
        )
        // MOB-13 不变量：kept 与 candidates 严格 1:1 同序。fileEntriesOf
        // 靠这条把 fileKey 配到 hash 上，长度对不上就整体降级成空 map。
        assertEquals(
            "kept 必须与 candidates 1:1 同序（MOB-13 fileEntriesOf 的前提）",
            built.candidates.map { it.fileName },
            built.kept.map { it.name },
        )
        // 候选不是空壳：open 还能真的读出内容，hash 是真算出来的 64 hex。
        built.candidates.forEach {
            assertEquals(1024, it.open().readBytes().size)
            assertEquals(64, it.hash.length)
        }
        dir.deleteRecursively()
    }

    @Test
    fun cached_hash_does_not_smuggle_a_deleted_file_into_the_batch() {
        // PERF-01 的洞：hashWithCache 命中缓存时不调 open，于是「上一轮
        // 哈希过、之后文件被删」的记录会带着旧 hash 溜进候选，直到
        // BackupRunner.pushFile 才抛 ENOENT——同样炸掉整批。探针 open
        // 就是堵这个洞（去掉探针 → 本测试红）。
        val dir = tempDir("cached")
        val cache = HashCache(File(dir, "hash-cache.json"))

        // 第一轮：文件还在，进缓存。
        val alive = Record("IMG_9.jpg", ByteArray(2048) { 3 })
        assertEquals(1, buildCandidates(listOf(alive), buildOf(cache)).candidates.size)

        // 第二轮：MediaStore 行没变（同 key，缓存命中），实体文件没了。
        val deleted = Record("IMG_9.jpg", null)
        val built = buildCandidates(listOf(deleted, good(4)), buildOf(cache))
        assertEquals(
            "缓存命中不能让已删除的文件混进批次",
            listOf("IMG_4.jpg"),
            built.candidates.map { it.fileName },
        )
        assertEquals(listOf("IMG_9.jpg"), built.skipped.map { it.name })
        dir.deleteRecursively()
    }

    @Test
    fun every_record_unreadable_yields_empty_batch_without_throwing() {
        // MOB-08 的现场就是这一形状（5 条坏记录、0 条好记录）。整批读不了
        // 不许抛——doWork 拿到空候选后直接 success 返回，不 commit 也不推
        // 进水位（推进了等于把这些行永久跳过）。
        val dir = tempDir("all-bad")
        val cache = HashCache(File(dir, "hash-cache.json"))
        val records = listOf(bad(1), bad(2), bad(3), bad(4), bad(5))

        val built = buildCandidates(records, buildOf(cache))

        assertTrue("整批坏记录必须得到空候选而不是异常", built.candidates.isEmpty())
        assertEquals(5, built.skipped.size)
        dir.deleteRecursively()
    }

    @Test
    fun a_late_read_error_is_skipped_too() {
        // 坏记录不止 ENOENT 一种：占位/云相册文件能 open、读一半 IOException，
        // SecurityException（权限被撤）也是同一类。都必须走跳过而不是炸批。
        val dir = tempDir("late")
        val cache = HashCache(File(dir, "hash-cache.json"))
        val truncated = object : InputStream() {
            override fun read(): Int = throw java.io.IOException("I/O error")
            override fun read(b: ByteArray, off: Int, len: Int): Int =
                throw java.io.IOException("I/O error")
        }
        val records = listOf<() -> InputStream>(
            { ByteArrayInputStream(ByteArray(512) { 1 }) },
            { truncated },
            { throw SecurityException("permission revoked") },
        )
        var i = 0
        val built = buildCandidates(records) { open ->
            val n = i++
            open().use { }
            Candidate(
                hash = hashWithCache(cache, "k$n", open),
                fileName = "F$n.jpg",
                mediaType = "image/jpeg",
                bytes = 512,
                open = open,
            )
        }
        assertEquals(listOf("F0.jpg"), built.candidates.map { it.fileName })
        assertEquals(2, built.skipped.size)
        dir.deleteRecursively()
    }

    @Test
    fun cancellation_is_never_treated_as_a_bad_record() {
        // MOB-08 回归锁：系统 stop（配额/约束/FGS 回收/超时）抛的是
        // CancellationException，它不是坏记录。吞掉它 = 把一次系统取消
        // 伪装成「全部跳过」的成功批次，水位与失败计数全乱。
        assertThrows(CancellationException::class.java) {
            buildCandidates(listOf(1, 2, 3)) { throw CancellationException("system stop") }
        }
    }

    @Test
    fun doWork_builds_candidates_through_the_isolating_path() {
        // 接线锁：doWork 必须走 buildCandidates，不能退回裸 map。
        // codeOf 先剥注释——把这行代码注释掉也必须红。
        val src = codeOf(
            File(
                repoRoot(),
                "apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/BackupWorker.kt",
            )
        )
        // 候选构建那一段（hash 缓存开张 → 交给 BackupRunner 之前）。
        val buildBlock = src
            .substringAfter("val hashCache = HashCache(hashCacheFile(ctx))")
            .substringBefore("val report = BackupRunner(client)")
        assertTrue(
            "doWork 必须用逐条隔离的 buildCandidates 构建候选",
            buildBlock.contains("buildCandidates(scan.items)"),
        )
        assertTrue(
            "不允许退回裸 scan.items.map 建候选（一条打不开就炸整批）",
            !buildBlock.contains("scan.items.map"),
        )
        assertTrue(
            "被跳过的条目必须打 PPassBackup 日志（别静默吞）",
            buildBlock.contains("unreadable media record(s)"),
        )
        assertTrue(
            "整批读不了时不许推进水位（否则这些行被永久跳过）",
            buildBlock.contains("if (candidates.isEmpty())"),
        )
        // 探针 open 的锁只能在这里：上面 cached_hash_… 那个行为测试用的是
        // **测试自己写的** build lambda，把生产的探针删掉它照样绿（本卡实测
        // 过这个假绿）。生产链路上探针在不在，只有源码级断言看得见。
        assertTrue(
            "候选构建必须先探一次 open（缓存命中不调 open，删掉的文件会溜进批次）",
            buildBlock.contains("open().use { }"),
        )
        // MOB-13 交叉锁：文件级确认必须喂 kept，不能喂 scan.items——跳过
        // 坏记录后两者不等长，fileEntriesOf 会整体降级成空 map。
        assertTrue(
            "fileEntriesOf 必须喂 built.kept（与候选 1:1 同序）",
            src.contains("built.kept.map { it.uri.toString() to it.bucketId }"),
        )
    }
}
