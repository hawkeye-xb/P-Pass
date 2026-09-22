// MOB-100：R-CLEARABLE 的门禁。
//
// 规则（本卡落进 assets/design/tokens.json 的 rules 第 11 条）：
//   「任何常驻提示都必须有用户自己走得通的消除路径；只有开发者能清不算。」
//
// 为什么做成门禁而不是写篇文档：tokens.json 里已有的 10 条（三色语义、
// 正文字号下限、点击区下限…）字号写错了肉眼能看见，「提示消不掉」要等真实
// 用户用上几周、并且愿意开口抱怨才会被发现一次。本次就是这样被发现的。
//
// 清单来源：docs/design/2026-09-22-home-notice-priority.md §1 的 22 条
// （A 英雄卡 / B 正文 / C 设置卡 / D NoticeHost 槽位 / E 非卡片位），
// 外加本卡新增的 C4（已确认的「源已删除」那批的去处）。
//
// 门禁的四条判据：
//   1. 常驻 + 提示 ⇒ 消除路径不得为空；
//   2. 「重装 App」「解除配对」不算路径（大锤，不是路径）；
//   3. 账本类路径**可执行**：提示成立 → 跑一遍这条路径 → 提示必须不再成立。
//      这一条专门治 D3 那种形状（有按钮、按钮是 `= Unit`）——把出路换成
//      no-op，门禁当场红；
//   4. 「不适用」只允许出现在**非提示**（状态显示/动作）或**非常驻**的行上，
//      并且必须写明理由。
package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.backup.flow.AcknowledgeableNotice
import com.hawkeyexb.ppass.backup.flow.CancellationRoundController
import com.hawkeyexb.ppass.backup.flow.ConsumerGate
import com.hawkeyexb.ppass.backup.flow.DeliveryState
import com.hawkeyexb.ppass.backup.flow.DiscoveryCandidate
import com.hawkeyexb.ppass.backup.flow.DiscoveryCursor
import com.hawkeyexb.ppass.backup.flow.DiscoveryLedgerSnapshot
import com.hawkeyexb.ppass.backup.flow.DiscoveryLedgerStore
import com.hawkeyexb.ppass.backup.flow.RecoveryDisposition
import com.hawkeyexb.ppass.backup.flow.SourcePresence
import com.hawkeyexb.ppass.backup.flow.acknowledgeNotice
import com.hawkeyexb.ppass.backup.flow.flowCancelledRoundNotice
import com.hawkeyexb.ppass.backup.flow.flowMissingSourceNotice
import com.hawkeyexb.ppass.backup.flow.flowReuploadNoticeCount
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** 这一行是「提示」（会来打断用户），还是状态显示/动作（用户自己去看的账目）。 */
private enum class Role { NOTICE, STATUS }

/** 常驻（自己不会走）还是瞬态（条件变了/一次成功就自清）。 */
private enum class Presence { PERSISTENT, TRANSIENT }

private sealed interface ClearPath {
    /**
     * 账本类出路：可执行。[seed] 造出提示成立的账本，[clear] 跑用户点下去
     * 真正执行的那条路径，门禁验证提示随之不再成立。
     */
    data class Ledger(
        val description: String,
        val seed: (DiscoveryLedgerStore) -> Unit,
        val active: (DiscoveryLedgerSnapshot) -> Boolean,
        val clear: (DiscoveryLedgerStore) -> Unit,
    ) : ClearPath

    /** 系统/权限类出路：JVM 里跑不了（要真机），登记成有类型的动作描述。 */
    data class UserAction(val description: String) : ClearPath

    /** 不适用——只许给非提示行或非常驻行用，[reason] 必填。 */
    data class NotApplicable(val reason: String) : ClearPath
}

private data class NoticeEntry(
    val id: String,
    val name: String,
    val source: String,
    val role: Role,
    val presence: Presence,
    val path: ClearPath,
)

class MOB100NoticeClearPathTest {

    /** 去掉块注释与行注释——断言的是代码，不是注释里的引用。 */
    private fun codeOf(file: File): String =
        file.readText()
            .replace(Regex("/\\*.*?\\*/", RegexOption.DOT_MATCHES_ALL), "")
            .lines()
            .filterNot { it.trimStart().startsWith("//") }
            .joinToString("\n")

    private fun tempDir(case: String): File =
        java.nio.file.Files.createTempDirectory("ppass-mob100-gate-$case").toFile()

    private fun candidate(id: Long) = DiscoveryCandidate(
        sourceRef = "content://media/external/images/media/$id",
        sourceVersion = "1789878898:1052429",
        bucketId = 42L,
    )

    private fun seedOnePage(store: DiscoveryLedgerStore) {
        store.commitDiscoveryPage(
            listOf(candidate(1)),
            DiscoveryCursor(lastGeneration = 7L, lastMediaId = 1L),
        )
    }

    // ── 清单本体（交付物之一，不是附录） ────────────────────────────────
    private fun manifest(): List<NoticeEntry> = listOf(
        // 区 A — 英雄卡
        NoticeEntry(
            "A1", "no_media_access_title/body", "HomeScreen.kt 英雄卡权限分支",
            Role.NOTICE, Presence.PERSISTENT,
            ClearPath.UserAction("按钮「去设置」→ onOpenAppSettings → 系统设置授予相册权限"),
        ),
        NoticeEntry(
            "A2", "partial_access_title/body", "HomeScreen.kt 英雄卡权限分支",
            Role.NOTICE, Presence.PERSISTENT,
            ClearPath.UserAction("按钮「去设置」→ onOpenAppSettings → 授予完整相册权限"),
        ),
        NoticeEntry(
            "A3", "三元组主数字 + hero_of_n", "HomeScreen.kt 英雄卡主位",
            Role.STATUS, Presence.PERSISTENT,
            ClearPath.NotApplicable("状态显示，非提示——它说的是「你有多少张」，不要求用户做任何事"),
        ),
        NoticeEntry(
            "A4", "triplet_unavailable", "HomeScreen.kt 英雄卡 triplet == null 分支",
            // 一次成功扫描就自清 ⇒ 非常驻，三条违反里最软的一条，不在本卡。
            Role.NOTICE, Presence.TRANSIENT,
            ClearPath.NotApplicable(
                "非永久：任一次 refreshTriplet 成功就自清。用户当下确实没有可执行动作，" +
                    "按优先级表 §6 顺带发现 2 单独处理，本卡不碰（如实标注）",
            ),
        ),
        NoticeEntry(
            "A5", "dog_last_success / last_success_never / pending_count", "HomeScreen.kt 英雄卡副行",
            Role.STATUS, Presence.PERSISTENT,
            ClearPath.NotApplicable("状态显示，非提示"),
        ),
        NoticeEntry(
            "A6", "state_scanning/hashing/sending 进行中状态行", "HomeScreen.kt workingText",
            Role.STATUS, Presence.TRANSIENT,
            ClearPath.NotApplicable("瞬态状态显示，随传输结束自清"),
        ),
        NoticeEntry(
            "A7", "空闲态状态行（state_safe / state_pending / idle_auto_hint …）", "HomeScreen.kt idleStatusText",
            Role.STATUS, Presence.PERSISTENT,
            ClearPath.NotApplicable("状态显示，非提示；内容对不对由 #350 的规则 G/S 治理"),
        ),
        NoticeEntry(
            "A8", "backup_pause / backup_resume / backup_command_processing", "HomeScreen.kt heroActionOf",
            Role.STATUS, Presence.PERSISTENT,
            ClearPath.NotApplicable("动作按钮，非提示"),
        ),
        NoticeEntry(
            "A9", "backup_cancel_current_round", "HomeScreen.kt cancelAffordanceVisible",
            Role.STATUS, Presence.PERSISTENT,
            ClearPath.NotApplicable("动作按钮，非提示"),
        ),
        NoticeEntry(
            "A10", "6dp 进度条", "HomeScreen.kt RoundProgress",
            Role.STATUS, Presence.TRANSIENT,
            ClearPath.NotApplicable("瞬态进度显示"),
        ),
        // 区 B — 英雄卡下方正文
        NoticeEntry(
            "B1", "wifi_deferred_hint", "HomeScreen.kt shouldShowWifiDeferredHint",
            Role.NOTICE, Presence.PERSISTENT,
            ClearPath.UserAction("连上 Wi-Fi，或关掉设置卡里的「仅 Wi-Fi」开关"),
        ),
        NoticeEntry(
            "B2", "state_trouble + run_failed + try_again", "HomeScreen.kt Trouble 红卡",
            Role.NOTICE, Presence.PERSISTENT,
            ClearPath.UserAction("按钮「再试一次」→ FlowCommand.Retry"),
        ),
        NoticeEntry(
            "B3", "pairing_lost_title/body + reconnect", "HomeScreen.kt 配对失效红卡",
            Role.NOTICE, Presence.PERSISTENT,
            ClearPath.UserAction("按钮「重新扫码连接」→ onRepairPairing"),
        ),
        NoticeEntry(
            "B4", "missing_source_notice_body（本卡本体）", "HomeScreen.kt SOURCE_MISSING NoticeCard",
            Role.NOTICE, Presence.PERSISTENT,
            ClearPath.Ledger(
                description = "「知道了」→ BackupUiStateHolder.acknowledgeMissingSourceNotice() → " +
                    "FlowAction.AcknowledgeNotice(SOURCE_MISSING) → 账本按条打确认水位线（不删条目）",
                seed = { store ->
                    seedOnePage(store)
                    store.update { snapshot ->
                        snapshot.copy(
                            items = snapshot.items.map {
                                it.copy(
                                    deliveryState = DeliveryState.SKIPPED_SOURCE_MISSING,
                                    sourcePresence = SourcePresence.MISSING,
                                    disposition = RecoveryDisposition.UNRECOVERABLE,
                                )
                            },
                        )
                    }
                },
                active = { snapshot -> flowMissingSourceNotice(snapshot) != null },
                clear = { store ->
                    store.update { it.acknowledgeNotice(AcknowledgeableNotice.SOURCE_MISSING, 1_700_000_000_000L) }
                },
            ),
        ),
        // 区 C — 设置卡内
        NoticeEntry(
            "C1", "cancelled_round_cell_label/value（已跳过的照片 · 点击恢复）", "HomeScreen.kt 备份卡 CellRow",
            Role.NOTICE, Presence.PERSISTENT,
            ClearPath.Ledger(
                description = "点这一行 → restoreCancelledRounds → restoreAllCancelledFlowRounds → " +
                    "FlowRunner.restoreAllCancelledRounds → CancellationRoundController.restoreRound",
                seed = { store ->
                    seedOnePage(store)
                    store.update { it.copy(consumerGate = ConsumerGate.PAUSED_BY_USER) }
                    CancellationRoundController(store).startPausedRound("gate-round-1")
                },
                active = { snapshot -> flowCancelledRoundNotice(snapshot) != null },
                clear = { store ->
                    val controller = CancellationRoundController(store)
                    store.load().items
                        .mapNotNull {
                            if (it.deliveryState == DeliveryState.CANCELLED_BY_USER_ROUND) {
                                it.cancellationRoundId
                            } else {
                                null
                            }
                        }
                        .distinct()
                        .forEach { controller.restoreRound(it) }
                },
            ),
        ),
        NoticeEntry(
            "C2", "background_backup_needs_authorization（开关行 hint）", "HomeScreen.kt RuleSwitchRow hint",
            Role.NOTICE, Presence.PERSISTENT,
            ClearPath.UserAction("点 hint → resolveBackgroundBackup 申请电池白名单；或自己关掉「自动备份」开关"),
        ),
        NoticeEntry(
            "C3", "background_backup_system_stopped（开关行 hint）", "HomeScreen.kt RuleSwitchRow hint",
            Role.NOTICE, Presence.PERSISTENT,
            ClearPath.UserAction("点 hint → resolveBackgroundBackup；或自己关掉「自动备份」开关"),
        ),
        NoticeEntry(
            // 本卡新增：B4 确认之后那批事实的去处（关键判断 3）。
            "C4", "missing_source_archive_label/value（已从手机删除的照片 · 无法恢复）",
            "HomeScreen.kt 备份卡 CellRow（onClick == null，不可点、不画「›」）",
            Role.STATUS, Presence.PERSISTENT,
            ClearPath.NotApplicable(
                "状态显示，非提示：它**只有用户自己点过「知道了」之后才出现**，是那批事实的去处" +
                    "（MOB-59 教训：提示消失了、那批再也找不到），不打断、不要求任何动作；" +
                    "源已不在手机上，没有任何动作能把它变回来（MOB-61 不给重传按钮）",
            ),
        ),
        // 区 D — NoticeHost 槽位
        NoticeEntry(
            "D1", "background_backup_needs_authorization（横幅）", "HomeNotices.kt BACKUP_INTERRUPTED",
            Role.NOTICE, Presence.PERSISTENT,
            ClearPath.UserAction("background_backup_notice_action「去处理」→ resolveBackgroundBackup"),
        ),
        NoticeEntry(
            "D2", "background_backup_system_stopped（横幅）", "HomeNotices.kt BACKUP_INTERRUPTED",
            Role.NOTICE, Presence.PERSISTENT,
            ClearPath.UserAction("background_backup_notice_action「去处理」→ resolveBackgroundBackup"),
        ),
        NoticeEntry(
            "D3", "reupload_notice_body + reupload_notice_action「知道了」", "HomeNotices.kt REUPLOAD",
            Role.NOTICE, Presence.PERSISTENT,
            ClearPath.Ledger(
                description = "「知道了」→ BackupUiStateHolder.acknowledgeReuploadNotice() → " +
                    "FlowAction.AcknowledgeNotice(REUPLOAD) → 账本按条打确认水位线（不删条目）",
                seed = { store ->
                    seedOnePage(store)
                    store.update { snapshot ->
                        snapshot.copy(
                            items = snapshot.items.map {
                                it.copy(
                                    deliveryState = DeliveryState.CONFIRMED,
                                    disposition = RecoveryDisposition.NEEDS_DECISION,
                                )
                            },
                        )
                    }
                },
                active = { snapshot -> flowReuploadNoticeCount(snapshot) > 0 },
                clear = { store ->
                    store.update { it.acknowledgeNotice(AcknowledgeableNotice.REUPLOAD, 1_700_000_000_000L) }
                },
            ),
        ),
        // 区 E — 非卡片位
        NoticeEntry(
            "E1", "设置 tab 图标红点", "MainActivity.kt TwoTabs",
            Role.STATUS, Presence.PERSISTENT,
            ClearPath.NotApplicable("随 B3 / C2 / C3 消除而消除，自己没有独立内容"),
        ),
        NoticeEntry(
            "E2", "background_backup_resuming（snackbar）", "MainActivity.kt resolveBackgroundBackup",
            Role.STATUS, Presence.TRANSIENT,
            ClearPath.NotApplicable("瞬态，自动消失"),
        ),
    )

    private val bannedPaths = listOf("重装", "reinstall", "解除配对", "unpair", "恢复出厂", "factory reset")

    // ── 判据 1：常驻提示不得没有出路 ─────────────────────────────────────
    @Test
    fun every_persistent_notice_has_a_clear_path() {
        val offenders = manifest().filter {
            it.role == Role.NOTICE && it.presence == Presence.PERSISTENT && it.path is ClearPath.NotApplicable
        }
        assertTrue(
            "R-CLEARABLE：常驻提示的消除路径不得为空。没有出路的行：" +
                offenders.joinToString { "${it.id} ${it.name}" },
            offenders.isEmpty(),
        )
    }

    @Test
    fun no_clear_path_is_blank() {
        manifest().forEach { entry ->
            val text = when (val path = entry.path) {
                is ClearPath.Ledger -> path.description
                is ClearPath.UserAction -> path.description
                is ClearPath.NotApplicable -> path.reason
            }
            assertTrue("${entry.id} 的路径/理由是空的——清单不许有占位行", text.isNotBlank())
        }
    }

    // ── 判据 2：大锤不算路径 ─────────────────────────────────────────────
    @Test
    fun reinstalling_the_app_or_unpairing_is_not_a_clear_path() {
        manifest().forEach { entry ->
            val text = when (val path = entry.path) {
                is ClearPath.Ledger -> path.description
                is ClearPath.UserAction -> path.description
                is ClearPath.NotApplicable -> ""
            }.lowercase()
            bannedPaths.forEach { banned ->
                assertFalse(
                    "${entry.id}：「$banned」是大锤，不是消除路径",
                    text.contains(banned.lowercase()),
                )
            }
        }
    }

    // ── 判据 3：账本类出路必须真的做事（治 D3 那种 no-op 形状） ──────────
    @Test
    fun every_ledger_clear_path_actually_clears_the_notice() {
        manifest().forEach { entry ->
            val path = entry.path as? ClearPath.Ledger ?: return@forEach
            val dir = tempDir(entry.id.lowercase())
            try {
                val store = DiscoveryLedgerStore(dir)
                path.seed(store)
                assertTrue(
                    "${entry.id} 的前提没造出来：提示本来就不成立，这条门禁等于没跑",
                    path.active(store.load()),
                )

                path.clear(store)

                assertFalse(
                    "${entry.id} 的「出路」跑完，提示依然成立 —— 一个 no-op 按钮不是路径。" +
                        "登记的路径：${path.description}",
                    path.active(DiscoveryLedgerStore(dir).load()),
                )
            } finally {
                dir.deleteRecursively()
            }
        }
    }

    // ── 判据 4：「不适用」只许给非提示/非常驻的行 ────────────────────────
    @Test
    fun not_applicable_is_only_allowed_for_status_rows_or_transient_notices() {
        manifest().forEach { entry ->
            if (entry.path is ClearPath.NotApplicable) {
                assertTrue(
                    "${entry.id}：常驻的提示行不许用「不适用」把自己放过去",
                    entry.role == Role.STATUS || entry.presence == Presence.TRANSIENT,
                )
            }
        }
    }

    // 可追溯性：清单必须盖住优先级表 §1 的 22 条，不许悄悄少几行糊过去。
    @Test
    fun the_manifest_still_covers_every_row_of_the_priority_table() {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        val doc = File(dir, "docs/design/2026-09-22-home-notice-priority.md").readText()
        assertTrue("事实源 §1 的合计行变了，清单要跟着对一遍", doc.contains("**合计 22 条**"))

        val ids = manifest().map { it.id }
        assertEquals("清单里有重复 id", ids.size, ids.distinct().size)
        val fromTable = ids.filterNot { it == "C4" }
        assertEquals(
            "优先级表 §1 是 22 条，清单里来自表的行必须也是 22 条（C4 是本卡新增的去处行）",
            22,
            fromTable.size,
        )
        assertEquals(23, ids.size)
    }

    // D3 的反证锚点：holder 的那两个函数必须真的投一条 action 出去。
    // 改回 `fun acknowledgeReuploadNotice() = Unit` ⇒ 本用例红。
    @Test
    fun the_home_acknowledge_buttons_are_wired_to_the_ledger() {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        // 注释先剥掉——KDoc 里正引用着 `= Unit` 那句旧代码当反面教材，
        // 拿原文断言会被自己的注释骗过去（同 ForegroundServiceWiringTest 的 codeOf）。
        val holder = codeOf(
            File(
                dir,
                "apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/BackupUiStateHolder.kt",
            ),
        )
        assertFalse(
            "acknowledgeReuploadNotice 不许再是空函数——有按钮、按钮不做事比没按钮更坏",
            holder.contains("fun acknowledgeReuploadNotice() = Unit"),
        )
        listOf("acknowledgeReuploadNotice", "acknowledgeMissingSourceNotice").forEach { name ->
            val body = holder.substringAfter("fun $name()").substringBefore("\n    }")
            assertTrue(
                "$name 必须走 acknowledge(...) → acknowledgeFlowNotice，把确认真的落进账本",
                body.contains("acknowledge(AcknowledgeableNotice."),
            )
        }
        assertTrue(
            "holder 必须经单写者入口写账本（acknowledgeFlowNotice），不许在 UI 线程上直接 update",
            holder.contains("acknowledgeFlowNotice(context, notice)"),
        )

        val screen = File(
            dir,
            "apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/HomeScreen.kt",
        ).readText()
        assertTrue(
            "B4 的 NoticeCard 必须带 dismiss 出路（而不是 actionLabel——那会被读成「再传一次」，" +
                "MOB-61 的决定是不给重传按钮）",
            screen.contains("dismissLabel = stringResource(R.string.missing_source_notice_dismiss)") &&
                screen.contains("onDismiss = onAcknowledgeMissingSource"),
        )
        assertTrue(
            "确认过的那批必须有去处（关键判断 3）",
            screen.contains("R.string.missing_source_archive_label"),
        )

        val main = File(
            dir,
            "apps/android/app/src/main/java/com/hawkeyexb/ppass/MainActivity.kt",
        ).readText()
        assertTrue(
            "HomeScreen 的确认回调必须接到 holder 上，否则出路只在参数表里存在",
            main.contains("onAcknowledgeMissingSource = { holder.acknowledgeMissingSourceNotice() }"),
        )
    }

    // 规则本体必须落盘（本卡的交付物之一）。
    @Test
    fun the_rule_itself_is_in_the_design_tokens() {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        val tokens = File(dir, "assets/design/tokens.json").readText()
        assertTrue(
            "R-CLEARABLE 必须与既有 10 条同级、同双语格式地进 tokens.json 的 rules",
            tokens.contains(
                "Any persistent notice must have a path the user can take to clear it; " +
                    "developer-only cleanup does not count. " +
                    "任何常驻提示都必须有用户自己走得通的消除路径；只有开发者能清不算。",
            ),
        )
        val siteCss = File(dir, "site/src/styles/tokens.css").readText()
        assertTrue(
            "site 的生成物把 rules 一起嵌进产物（SITE-04）——tokens.json 改了必须重跑生成器",
            siteCss.contains("Any persistent notice must have a path the user can take to clear it"),
        )
    }
}
