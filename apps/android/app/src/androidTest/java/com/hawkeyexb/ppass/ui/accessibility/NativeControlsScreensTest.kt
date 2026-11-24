// 原生控件回归（E2）：次级页统一走 Scaffold + TopAppBar（标题 heading、返回可点），
// 列表行统一走 Material3 ListItem（整行可点、开关仍由整行承载）。
//
// 断言对象是 UiAutomation 读到的 a11y 树——与 TalkBack 消费的是同一棵树；
// 判定的是行为（点击回调、checked 翻转、页面切换），不读产品源码。

package com.hawkeyexb.ppass.ui.accessibility

import android.os.Build
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.compose.runtime.mutableStateOf
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.backup.MediaAccess
import com.hawkeyexb.ppass.backup.MediaScanner
import com.hawkeyexb.ppass.ui.BackupUiState
import com.hawkeyexb.ppass.ui.BucketScreen
import com.hawkeyexb.ppass.ui.FolderScreen
import com.hawkeyexb.ppass.ui.FolderUi
import com.hawkeyexb.ppass.ui.HomeScreen
import com.hawkeyexb.ppass.ui.ManualPairScreen
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeControlsScreensTest {

    private fun label(res: Int): String = testContext.getString(res)

    private fun nodeByText(text: String): AccessibilityNodeInfo =
        awaitNode("节点「$text」") {
            it.text?.toString() == text || it.contentDescription?.toString() == text
        }

    private fun clickByText(text: String) {
        val target = nodeByText(text).clickableSelfOrAncestor()
            ?: throw AssertionError("「$text」必须可点；树：\n${describeTree()}")
        assertTrue("ACTION_CLICK 必须被「$text」接受", target.performAction(AccessibilityNodeInfo.ACTION_CLICK))
    }

    /** 页标题必须带 heading 语义；旧系统读不到 isHeading，只等文本出现。 */
    private fun awaitHeading(text: String) {
        awaitNode("标题「$text」带 heading") { n ->
            val textMatches = n.text?.toString() == text || n.contentDescription?.toString() == text
            textMatches && (Build.VERSION.SDK_INT < Build.VERSION_CODES.P || n.isHeading)
        }
    }

    /** 等「子树里带 [desc] 的 checkable 节点」到达期望 checked（行/卡的状态由容器承载）。 */
    private fun awaitCardChecked(desc: String, expected: Boolean): AccessibilityNodeInfo {
        val deadline = SystemClock.elapsedRealtime() + 5_000
        while (SystemClock.elapsedRealtime() < deadline) {
            a11yRoot()?.let { root ->
                walk(root)
                    .firstOrNull { n ->
                        n.isCheckable &&
                            walk(n).any { it.contentDescription?.toString() == desc } &&
                            n.isChecked == expected
                    }
                    ?.let { return it }
            }
            Thread.sleep(200)
        }
        throw AssertionError("「$desc」的 checked 没有变成 $expected；树：\n${describeTree()}")
    }

    /** 等「子树里合并了 [text] 的 checkable 行」到达期望 checked（开关行整行一个语义节点）。 */
    private fun awaitRowChecked(text: String, expected: Boolean): AccessibilityNodeInfo {
        val deadline = SystemClock.elapsedRealtime() + 5_000
        while (SystemClock.elapsedRealtime() < deadline) {
            a11yRoot()?.let { root ->
                walk(root)
                    .firstOrNull { n ->
                        n.isCheckable &&
                            walk(n).any { it.text?.toString() == text } &&
                            n.isChecked == expected
                    }
                    ?.let { return it }
            }
            Thread.sleep(200)
        }
        throw AssertionError("开关行「$text」没有变成 checked=$expected；树：\n${describeTree()}")
    }

    @Test
    fun folder_screen_has_a_native_app_bar_with_back_navigation() {
        var backCount = 0
        hostCompose(
            {
                FolderScreen(
                    folders = listOf(FolderUi(id = "f-1", name = "Camera", needsPermission = false)),
                    onAdd = {},
                    onRemove = {},
                    onReauthorize = {},
                    onBack = { backCount++ },
                )
            },
        ) {
            awaitHeading(label(R.string.folder_settings_title))
            clickByText(label(R.string.back))
            assertEquals("返回按钮必须回调一次", 1, backCount)
            saveTree("native-folder-appbar.txt", a11yRoot())
        }
    }

    @Test
    fun folder_removal_still_goes_through_the_confirmation_dialog() {
        val removed = mutableListOf<FolderUi>()
        val folder = FolderUi(id = "f-1", name = "DCIM", needsPermission = false)
        hostCompose(
            {
                FolderScreen(
                    folders = listOf(folder),
                    onAdd = {},
                    onRemove = { removed += it },
                    onReauthorize = {},
                    onBack = {},
                )
            },
        ) {
            clickByText(label(R.string.folder_remove))
            assertEquals("点移除只挂起待确认，不得直接移除", 0, removed.size)
            // 弹窗是独立窗口：先看到弹窗标题，再点确认，避免重新点到行内那个「移除」。
            nodeByText(testContext.getString(R.string.folder_remove_confirm_title, folder.name))
            clickByText(label(R.string.folder_remove_confirm_action))
            assertEquals("确认后只移除挂起的那一条", listOf(folder), removed)
            saveTree("native-folder-removal.txt", a11yRoot())
        }
    }

    @Test
    fun bucket_screen_has_a_native_app_bar_and_album_cards_still_toggle() {
        var cancelCount = 0
        val album = MediaScanner.Bucket(id = 1L, name = "Camera", count = 3)
        hostCompose(
            {
                BucketScreen(
                    buckets = listOf(album),
                    selected = emptySet(),
                    sinceLabel = label(R.string.scope_time_all),
                    firstTime = false,
                    albumAccess = MediaAccess.FULL,
                    onDone = { _, _, _ -> },
                    onCancel = { cancelCount++ },
                )
            },
        ) {
            awaitHeading(label(R.string.backup_scope))
            val albumKind = label(R.string.source_kind_album)
            val card = awaitCardChecked(albumKind, expected = false)
            assertTrue("相册卡整卡必须可点", card.isClickable)
            assertTrue("ACTION_CLICK 必须被相册卡接受", card.performAction(AccessibilityNodeInfo.ACTION_CLICK))
            assertTrue("点相册卡后 checked 必须翻转", awaitCardChecked(albumKind, expected = true).isChecked)
            clickByText(label(R.string.back))
            assertEquals("返回按钮必须回调一次", 1, cancelCount)
            saveTree("native-bucket-appbar.txt", a11yRoot())
        }
    }

    @Test
    fun home_secondary_pages_use_native_app_bars_and_back_returns_home() {
        hostCompose({
            HomeScreen(storageName = "storage-pc", state = BackupUiState.Idle, onBackupNow = {})
        }) {
            clickByText(label(R.string.more_label))
            awaitHeading(label(R.string.more_label))
            clickByText(label(R.string.back))
            nodeByText(label(R.string.auto_backup_rule_label))

            clickByText(label(R.string.more_label))
            nodeByText(label(R.string.storage_computer))
            clickByText(label(R.string.storage_computer))
            awaitHeading(label(R.string.storage_computer))
            // 详情页返回先落回「更多」页（showMore 仍为开），再返回才回首页；
            // 按现有的返回层级分两步断言，不为测试改业务。
            clickByText(label(R.string.back))
            awaitHeading(label(R.string.more_label))
            clickByText(label(R.string.back))
            nodeByText(label(R.string.auto_backup_rule_label))
            saveTree("native-home-secondary.txt", a11yRoot())
        }
    }

    @Test
    fun manual_pair_screen_uses_a_native_app_bar_and_back_leaves_the_page() {
        var backCount = 0
        hostCompose({
            ManualPairScreen(
                input = "",
                onInputChange = {},
                error = false,
                onBack = { backCount++ },
                onSubmit = {},
            )
        }) {
            // 手动输入配对串曾是手写「‹」+ 裸字号顶栏，这里钉住它现在走原生 TopAppBar。
            awaitHeading(label(R.string.scan_manual_title))
            clickByText(label(R.string.back))
            assertEquals("返回按钮必须回调一次", 1, backCount)
            saveTree("native-manual-pair-appbar.txt", a11yRoot())
        }
    }

    @Test
    fun home_switch_row_still_toggles_from_the_whole_row() {
        val wifiOnly = mutableStateOf(true)
        hostCompose(
            {
                HomeScreen(
                    storageName = "storage-pc",
                    state = BackupUiState.Idle,
                    onBackupNow = {},
                    wifiOnly = wifiOnly.value,
                    onWifiOnlyChange = { wifiOnly.value = it },
                )
            },
        ) {
            val wifiLabel = label(R.string.setting_wifi_only)
            val row = awaitRowChecked(wifiLabel, expected = true)
            assertEquals(
                "开关行整行一个 checkable 节点，行内 Switch 不单独暴露",
                1,
                walk(row).count { it.isCheckable },
            )
            assertTrue("整行必须接受 ACTION_CLICK", row.performAction(AccessibilityNodeInfo.ACTION_CLICK))
            awaitRowChecked(wifiLabel, expected = false)
            assertFalse("点整行后开关必须关闭", wifiOnly.value)
            saveTree("native-home-switch-row.txt", a11yRoot())
        }
    }
}
