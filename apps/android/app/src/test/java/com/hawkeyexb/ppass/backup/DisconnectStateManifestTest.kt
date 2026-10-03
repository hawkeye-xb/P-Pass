// MOB-95（#282）：断开清单的行为测试 + 登记门禁。
//
// 1. 行为：用**真的 store** 把每一行清单状态写进一个假的 App 数据目录 →
//    跑生产里 clearLocalPairing 执行的同一个 applyDisconnectManifest →
//    逐行断言留 / 清 / 改写 / 停。
// 2. 门禁（文件层）：写完之后遍历 files/、shared_prefs/、databases/，每个路径
//    都必须落在某一行清单里（unregisteredStatePaths 也是真机断开时打日志用的那个）。
// 3. 门禁（编译产物）：解析 app 编译出的每一个 .class，凡是构造参数带
//    java.io.File、或调用 SharedPreferences / 数据库 API 的类，都必须是某一行
//    清单的 owner，或者在下面「不是持久状态」的白名单里写明理由。
//    解析的是字节码常量池与方法表，不读源码。
package com.hawkeyexb.ppass.backup

import com.hawkeyexb.ppass.backup.flow.FlowControlStore
import com.hawkeyexb.ppass.transport.IdentityStore
import com.hawkeyexb.ppass.transport.Pairing
import com.hawkeyexb.ppass.transport.PairingStore
import com.hawkeyexb.ppass.update.UpdatePrefs
import java.io.DataInputStream
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class DisconnectStateManifestTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private val nodeId = "a".repeat(64)
    private lateinit var dataDir: File
    private lateinit var filesDir: File

    @Before
    fun layout() {
        dataDir = tmp.newFolder("data")
        filesDir = File(dataDir, "files").apply { mkdirs() }
    }

    private class RecordingRuntime : DisconnectRuntime {
        var flowStopped = false
        var mediaWatchCancelled = false
        val cancelled = mutableListOf<String>()
        override fun stopFlowRuntime() {
            flowStopped = true
        }
        override fun cancelUniqueWork(name: String) {
            cancelled += name
        }
        override fun cancelMediaWatch() {
            mediaWatchCancelled = true
        }
    }

    /**
     * 每一行清单各写一份。`when` 穷举：清单新增一行而这里不补写法，编译不过。
     * files/ 下的全部用生产 store 写；shared_prefs / databases / 原生仓库在 JVM 上
     * 跑不起来（本仓没有 Robolectric），按它们在设备上的真实文件名落一个文件。
     */
    private fun seed(state: DisconnectState) {
        val legacyDir = File(filesDir, "backup-state/$nodeId")
        when (state) {
            DisconnectState.PAIRING -> PairingStore(filesDir).save(
                Pairing(daemonNodeId = nodeId, daemonAddrToken = "t", storageDeviceName = "Home"),
            )
            DisconnectState.AUTO_BACKUP_PREFS -> AutoBackupPrefs(filesDir).apply {
                setRequested(true)
                setEnabled(true)
            }
            DisconnectState.IDENTITY -> IdentityStore(filesDir).secretKey()
            DisconnectState.ONBOARDED_DESKTOPS -> OnboardedDesktopsStore(filesDir).markOnboarded(nodeId)
            DisconnectState.BACKUP_SCOPE -> fake("shared_prefs/backup_scope-$nodeId.xml")
            DisconnectState.BACKUP_SCOPE_LEGACY -> fake("shared_prefs/backup_scope.xml")
            DisconnectState.BACKUP_SETTINGS -> BackupSettings(filesDir).save(wifiOnly = false)
            DisconnectState.ORDER_DB -> {
                fake("databases/backup-orders.db")
                fake("databases/backup-orders.db-wal")
            }
            DisconnectState.NATIVE_BLOB_STORE -> fake("files/iroh-blobs-provider/blobs.db")
            DisconnectState.FLOW_MIGRATION_MARKER -> com.hawkeyexb.ppass.backup.flow.migrateLegacyFlowState(filesDir)
            DisconnectState.ONBOARDING_NOTIFICATION_ASK ->
                OnboardingNotificationAsk(filesDir).initIfAbsent(existingUser = true)
            DisconnectState.WORK_MANAGER_DB -> fake("databases/androidx.work.workdb")
            DisconnectState.FLOW_CONTROL -> FlowControlStore(filesDir).setPaused(true)
            DisconnectState.NOTIFY_ON_FAILURE_PREFS -> NotifyOnFailurePrefs(filesDir).setEnabled(false)
            DisconnectState.UPDATE_PREFS -> UpdatePrefs(filesDir).markChecked(now = 1L)
            DisconnectState.BACKUP_HEALTH -> BackupHealthPrefs(filesDir).recordInterrupted(now = 1L)
            DisconnectState.SENTINEL -> SentinelStore(filesDir).recordReachable(now = 1L)
            DisconnectState.DEFINITIVE_NOTICES ->
                DefinitiveNoticeStore(filesDir).save(DefinitiveNoticeState(notifiedLostEpoch = "e1"))
            DisconnectState.LEGACY_BACKUP_STATE -> {
                ConfirmedStore(legacyDir).recordRun(confirmed = setOf("h1"), lastSuccessAt = 1L)
                ReuploadQueue(legacyDir).add(setOf("k1"))
                PausePrefs(legacyDir).setPausedAt(1L)
                RunStartPrefs(legacyDir).setStartedAt(1L)
                ReuploadNoticePrefs(legacyDir).record(setOf("h1"), now = 1L)
            }
            DisconnectState.LEGACY_WATERMARK -> WatermarkStore(filesDir).save(42L)
            DisconnectState.LEGACY_HASH_CACHE -> HashCache(File(filesDir, "hash-cache.json")).apply {
                put("k", "h")
                flush()
            }
            DisconnectState.LEGACY_BACKUP_ATTEMPT -> BackupAttemptStore(filesDir).recordFailure()
            DisconnectState.LEGACY_WHITELIST_NUDGE -> WhitelistNudgeStore(filesDir).recordFailure(now = 1L)
            DisconnectState.LEGACY_FLOW_LEDGER -> fake("files/flow-state/$nodeId/discovery-ledger.json")
            DisconnectState.LEGACY_TRANSFER_PROTECTION -> fake("files/flow-transfer-protection.json")
            DisconnectState.FLOW_RUNTIME,
            DisconnectState.AUTO_BACKUP_WORKS,
            DisconnectState.OTHER_WORKS,
            DisconnectState.MEDIA_WATCH_JOB,
            -> Unit // 不落盘
        }
    }

    private fun fake(rel: String) {
        File(dataDir, rel).apply { parentFile.mkdirs() }.writeText("x")
    }

    /** 某一行清单在盘上的全部文件 → 内容。 */
    private fun snapshot(state: DisconnectState): Map<String, String> {
        val root = File(dataDir, state.location.dirName ?: return emptyMap())
        return root.walkTopDown().filter { it.isFile }
            .map { it.relativeTo(root).invariantSeparatorsPath to it }
            .filter { (rel, _) -> state.matches(rel) }
            .associate { (rel, f) -> rel to f.readText() }
    }

    private fun seedAll() {
        // 迁移标记要先落：它的一次性迁移会删掉旧 flow-state，放在后面会把刚写的旧账本也删了。
        seed(DisconnectState.FLOW_MIGRATION_MARKER)
        DisconnectState.entries.filter { it != DisconnectState.FLOW_MIGRATION_MARKER }.forEach(::seed)
    }

    // ── 1. 行为：写入各状态 → 断开 → 逐行断言 ─────────────────────
    @Test
    fun disconnect_does_exactly_what_the_manifest_says_for_every_state() {
        seedAll()
        val before = DisconnectState.entries.associateWith(::snapshot)
        for (state in DisconnectState.entries.filter { it.location != StateLocation.RUNTIME }) {
            assertTrue("$state 没写出任何文件——这一行的写法或路径模式是错的", before.getValue(state).isNotEmpty())
        }

        val runtime = RecordingRuntime()
        applyDisconnectManifest(filesDir, runtime)

        for (state in DisconnectState.entries) {
            val after = snapshot(state)
            when (state.disposition) {
                DisconnectDisposition.KEEP, DisconnectDisposition.RETIRED ->
                    assertEquals("$state 是 ${state.disposition}：断开后必须原样还在", before.getValue(state), after)
                DisconnectDisposition.CLEAR ->
                    assertTrue("$state 是 CLEAR：断开后必须没有了，实际还剩 ${after.keys}", after.isEmpty())
                DisconnectDisposition.RESET ->
                    assertTrue("$state 是 RESET：文件留着、内容改写", after.isNotEmpty())
                DisconnectDisposition.STOP -> Unit // 下面按运行时记账断言
            }
        }

        // RESET 的逐项语义。
        if (DisconnectState.AUTO_BACKUP_PREFS.disposition == DisconnectDisposition.RESET) {
            assertFalse("MOB-93：断开停生产者", AutoBackupPrefs(filesDir).enabled())
            assertTrue("MOB-93：断开留意图", AutoBackupPrefs(filesDir).requested())
        }

        // STOP / 运行时 KEEP。
        fun stopped(s: DisconnectState) = s.disposition == DisconnectDisposition.STOP
        assertEquals(stopped(DisconnectState.FLOW_RUNTIME), runtime.flowStopped)
        assertEquals(stopped(DisconnectState.MEDIA_WATCH_JOB), runtime.mediaWatchCancelled)
        assertEquals(
            "取消的 unique work 必须正好是清单里 STOP 的那几行",
            DisconnectState.entries.filter(::stopped).flatMap { it.workNames }.toSet(),
            runtime.cancelled.toSet(),
        )

        assertEquals("断开之后也不许留下清单之外的东西", emptyList<String>(), unregisteredStatePaths(dataDir))
    }

    @Test
    fun the_behaviour_that_other_cards_decided_is_unchanged() {
        // #282 验收 4：账本、相册选择、Wi-Fi/充电仍保留；配对记录、租约、生产者仍清停。
        // #461：「连过这台」要留。红线：身份。
        val keep = listOf(
            DisconnectState.IDENTITY, DisconnectState.ONBOARDED_DESKTOPS, DisconnectState.BACKUP_SCOPE,
            DisconnectState.BACKUP_SETTINGS, DisconnectState.ORDER_DB, DisconnectState.NATIVE_BLOB_STORE,
        )
        keep.forEach { assertEquals(it.name, DisconnectDisposition.KEEP, it.disposition) }
        assertEquals(DisconnectDisposition.CLEAR, DisconnectState.PAIRING.disposition)
        assertEquals(DisconnectDisposition.RESET, DisconnectState.AUTO_BACKUP_PREFS.disposition)
        listOf(DisconnectState.FLOW_RUNTIME, DisconnectState.AUTO_BACKUP_WORKS, DisconnectState.MEDIA_WATCH_JOB)
            .forEach { assertEquals(it.name, DisconnectDisposition.STOP, it.disposition) }
        assertEquals(
            listOf(BACKUP_WORK_NAME, CATCHUP_WORK_NAME, PROCESS_CATCHUP_WORK_NAME, MANUAL_BACKUP_WORK_NAME),
            DisconnectState.AUTO_BACKUP_WORKS.workNames,
        )
        assertEquals("配对凭据最先作废（原 clearLocalPairing 的次序）", DisconnectState.PAIRING, DisconnectState.entries.first())
    }

    @Test
    fun manifest_rows_are_well_formed() {
        for (s in DisconnectState.entries) {
            assertTrue("$s 缺依据", s.basis.isNotBlank())
            if (s.disposition == DisconnectDisposition.CLEAR || s.disposition == DisconnectDisposition.RESET) {
                assertEquals("$s：${s.disposition} 只能落在 files/", StateLocation.FILES, s.location)
            }
            if (s.location == StateLocation.RUNTIME) {
                assertTrue("$s：运行时生产者只能 STOP / KEEP", s.disposition in setOf(DisconnectDisposition.STOP, DisconnectDisposition.KEEP))
            } else {
                assertTrue("$s：STOP 只用于运行时生产者", s.disposition != DisconnectDisposition.STOP)
            }
        }
    }

    // ── 2. 门禁（文件层）──────────────────────────────────────────
    @Test
    fun every_file_the_stores_write_is_registered() {
        seedAll()
        assertEquals(emptyList<String>(), unregisteredStatePaths(dataDir))
    }

    @Test
    fun an_unregistered_file_is_caught() {
        seedAll()
        fake("files/brand_new_store.json")
        fake("shared_prefs/brand_new_prefs.xml")
        File(filesDir, "empty-dir").mkdirs()
        assertEquals(
            listOf("files/brand_new_store.json", "files/empty-dir", "shared_prefs/brand_new_prefs.xml"),
            unregisteredStatePaths(dataDir),
        )
    }

    // ── 3. 门禁（编译产物）────────────────────────────────────────

    /** 构造参数带 File、但不是持久状态的类。新增一行要写明理由。 */
    private val notPersistentState = mapOf(
        "com.hawkeyexb.ppass.ui.VideoState" to "播放器状态（cacheDir 里的临时视频文件），不是持久状态",
    )

    private data class ClassInfo(val name: String, val superName: String?, val initDescriptors: List<String>, val utf8: Set<String>)

    private val stateApis = setOf(
        "getSharedPreferences", "deleteSharedPreferences", "openOrCreateDatabase", "getDatabasePath",
        "deleteDatabase", "getNoBackupFilesDir", "getDataDir", "openFileOutput",
    )

    @Test
    fun every_class_that_can_hold_app_state_is_registered() {
        val classes = compiledAppClasses()
        assertTrue("没扫到编译产物（${classes.size} 个类）——门禁空转", classes.size > 100)

        val suspects = classes.filter { c ->
            !isGenerated(c.name) && (
                c.initDescriptors.any { "Ljava/io/File;" in it } ||
                    c.utf8.any { it in stateApis } ||
                    c.superName == "android/database/sqlite/SQLiteOpenHelper"
                )
        }.map { outermost(it.name) }.toSortedSet()

        // 探测本身不许空转：已知的三种持久化形态（files/ JSON、SharedPreferences、SQLite）都得被认出来。
        for (known in listOf(
            "com.hawkeyexb.ppass.transport.PairingStore",
            "com.hawkeyexb.ppass.backup.BackupScopeStore",
            "com.hawkeyexb.ppass.backup.order.SqliteOrderStore",
        )) {
            assertTrue("探测没认出 $known——门禁空转", known in suspects)
        }

        val owners = DisconnectState.entries.flatMap { it.owners }.toSet()
        val unregistered = suspects - owners - notPersistentState.keys
        assertEquals(
            "这些类能读写持久状态，却没有登记进 DisconnectState（或写明理由放进白名单）",
            emptySet<String>(),
            unregistered,
        )

        val known = classes.map { outermost(it.name) }.toSet()
        assertEquals("清单 owner 指向了不存在的类（改名 / 删类后没同步）", emptySet<String>(), owners - known)
        assertEquals("白名单里有已经不存在的类", emptySet<String>(), notPersistentState.keys - known)
    }

    /** Kotlin 生成的 lambda / 协程状态机 / 匿名对象：名字里某一段是纯数字或带 lambda。 */
    private fun isGenerated(binaryName: String): Boolean =
        binaryName.split('$').drop(1).any { seg -> seg.isEmpty() || seg.all(Char::isDigit) || "lambda" in seg }

    private fun outermost(binaryName: String): String = binaryName.substringBefore('$').replace('/', '.')

    /** app 自己的编译产物（单测 classpath 上是目录或 classes.jar，两种都认）。 */
    private fun compiledAppClasses(): List<ClassInfo> {
        val root = File(DisconnectState::class.java.protectionDomain.codeSource.location.toURI())
        val prefix = "com/hawkeyexb/ppass/"
        return if (root.isDirectory) {
            File(root, prefix).walkTopDown()
                .filter { it.isFile && it.name.endsWith(".class") }
                .map { f -> f.inputStream().use { parseClass(it, f.path) } }
                .toList()
        } else {
            java.util.zip.ZipFile(root).use { zip ->
                zip.entries().asSequence()
                    .filter { it.name.startsWith(prefix) && it.name.endsWith(".class") }
                    .map { e -> zip.getInputStream(e).use { parseClass(it, e.name) } }
                    .toList()
            }
        }
    }

    /** 最小 class 文件解析：常量池里的 Utf8、this/super、全部 `<init>` 的描述符。 */
    private fun parseClass(stream: java.io.InputStream, file: String): ClassInfo = DataInputStream(stream.buffered()).let { input ->
        check(input.readInt() == 0xCAFEBABE.toInt()) { "not a class file: $file" }
        input.readUnsignedShort()
        input.readUnsignedShort()
        val count = input.readUnsignedShort()
        val utf8 = arrayOfNulls<String>(count)
        val classRef = IntArray(count)
        var i = 1
        while (i < count) {
            when (val tag = input.readUnsignedByte()) {
                1 -> utf8[i] = input.readUTF()
                7 -> classRef[i] = input.readUnsignedShort()
                8, 16, 19, 20 -> input.readUnsignedShort()
                3, 4, 9, 10, 11, 12, 17, 18 -> input.readInt()
                5, 6 -> {
                    input.readLong()
                    i++
                }
                15 -> {
                    input.readUnsignedByte()
                    input.readUnsignedShort()
                }
                else -> error("unknown constant tag $tag in $file")
            }
            i++
        }
        input.readUnsignedShort()
        val thisName = utf8[classRef[input.readUnsignedShort()]]!!
        val superIndex = input.readUnsignedShort()
        val superName = if (superIndex == 0) null else utf8[classRef[superIndex]]
        repeat(input.readUnsignedShort()) { input.readUnsignedShort() }
        fun members(): List<Pair<String, String>> = List(input.readUnsignedShort()) {
            input.readUnsignedShort()
            val name = utf8[input.readUnsignedShort()]!!
            val desc = utf8[input.readUnsignedShort()]!!
            repeat(input.readUnsignedShort()) {
                input.readUnsignedShort()
                input.skipNBytes(input.readInt().toLong())
            }
            name to desc
        }
        members()
        val inits = members().filter { it.first == "<init>" }.map { it.second }
        ClassInfo(thisName, superName, inits, utf8.filterNotNull().toSet())
    }
}
