// #1884 E2：全覆盖补齐剩余页面标题的 heading 语义（A15：欢迎页、配对状态页、决定页、身份异常页、照片页配对失效卡）与
// 动态提示/错误文本的 liveRegion=polite 语义（A5：手动配对错误；A7：看图/视频保存提示、视频下载进度与封面错误；
// A13：首页通知条、照片页配对失效与重连/离线状态条）。
//
// 断言对象是 UiAutomation 读到的 a11y 树——与 TalkBack 消费同一棵树，不读产品源码。
// 反证：去掉对应生产节点的 `.semantics { heading() }` 或 `{ liveRegion = LiveRegionMode.Polite }`，
// 下面对应用例必须超时或断言失败变红。

package com.hawkeyexb.ppass.ui.accessibility

import android.os.Build
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.ui.ClosableNoticeCard
import com.hawkeyexb.ppass.ui.ConnectionState
import com.hawkeyexb.ppass.ui.DecisionScreen
import com.hawkeyexb.ppass.ui.HomeNotice
import com.hawkeyexb.ppass.ui.HomeNoticeKind
import com.hawkeyexb.ppass.ui.IdentityUnavailableScreen
import com.hawkeyexb.ppass.ui.ManualPairScreen
import com.hawkeyexb.ppass.ui.NoticeCard
import com.hawkeyexb.ppass.ui.PairStatusScreen
import com.hawkeyexb.ppass.ui.PhotosScreen
import com.hawkeyexb.ppass.ui.TimelineSubscriptionHolder
import com.hawkeyexb.ppass.ui.VideoCover
import com.hawkeyexb.ppass.ui.VideoFetchingStatus
import com.hawkeyexb.ppass.ui.ViewerNoticeText
import com.hawkeyexb.ppass.ui.WelcomeScreen
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class HeadingAndLiveRegionSemanticsTest {

    private fun label(res: Int): String = testContext.getString(res)

    private fun awaitHeading(text: String): AccessibilityNodeInfo =
        awaitNode("标题「$text」带 heading") { n ->
            n.text?.toString() == text &&
                (Build.VERSION.SDK_INT < Build.VERSION_CODES.P || n.isHeading)
        }

    private fun awaitPoliteLiveRegion(text: String): AccessibilityNodeInfo =
        awaitNode("动态提示「$text」带 liveRegion=polite") { n ->
            n.text?.toString() == text &&
                n.liveRegion == View.ACCESSIBILITY_LIVE_REGION_POLITE
        }

    @Test
    fun welcome_screen_headline_carries_heading_semantics() {
        hostCompose({ WelcomeScreen(onScan = {}, onManual = {}) }) {
            val node = awaitHeading(label(R.string.welcome_headline))
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                assertTrue("欢迎页主标题必须带 heading 语义", node.isHeading)
            }
            saveTree("a11y-welcome-heading.txt", a11yRoot())
        }
    }

    @Test
    fun pair_status_screen_title_carries_heading_semantics() {
        val title = "Waiting for confirmation"
        hostCompose({
            PairStatusScreen(
                title = title,
                body = "Confirm on your computer",
                action = null,
                loading = true,
            )
        }) {
            val node = awaitHeading(title)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                assertTrue("配对状态页标题必须带 heading 语义", node.isHeading)
            }
            saveTree("a11y-pair-status-heading.txt", a11yRoot())
        }
    }

    @Test
    fun decision_screen_title_carries_heading_semantics() {
        hostCompose({
            DecisionScreen(
                computerName = "storage-pc",
                onChooseScope = {},
                onPickPhotos = {},
                onPickFiles = {},
                photoPickerAvailable = true,
            )
        }) {
            val node = awaitHeading(label(R.string.decision_title))
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                assertTrue("决定页标题必须带 heading 语义", node.isHeading)
            }
            saveTree("a11y-decision-heading.txt", a11yRoot())
        }
    }

    @Test
    fun identity_unavailable_screen_title_carries_heading_semantics() {
        hostCompose({
            IdentityUnavailableScreen(
                resetFailed = false,
                onRetry = {},
                onReset = {},
            )
        }) {
            val node = awaitHeading(label(R.string.identity_unavailable_title))
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                assertTrue("身份不可用页标题必须带 heading 语义", node.isHeading)
            }
            saveTree("a11y-identity-unavailable-heading.txt", a11yRoot())
        }
    }

    @Test
    fun manual_pair_error_announces_via_polite_live_region() {
        hostCompose({
            ManualPairScreen(
                input = "bad-link",
                onInputChange = {},
                error = true,
                onBack = {},
                onSubmit = {},
            )
        }) {
            val node = awaitPoliteLiveRegion(label(R.string.scan_manual_invalid))
            assertEquals(
                "手动配对格式错误提示必须带 liveRegion=polite",
                View.ACCESSIBILITY_LIVE_REGION_POLITE,
                node.liveRegion,
            )
            saveTree("a11y-manual-pair-error-live.txt", a11yRoot())
        }
    }

    @Test
    fun home_notice_cards_announce_via_polite_live_region() {
        val body = label(R.string.background_backup_system_stopped)
        hostCompose({
            NoticeCard(
                HomeNotice(
                    kind = HomeNoticeKind.BACKUP_INTERRUPTED,
                    body = body,
                    actionLabel = label(R.string.background_backup_action_turn_on),
                    onAction = {},
                ),
            )
        }) {
            val node = awaitPoliteLiveRegion(body)
            assertEquals(
                "首页通知条正文必须带 liveRegion=polite",
                View.ACCESSIBILITY_LIVE_REGION_POLITE,
                node.liveRegion,
            )
            saveTree("a11y-notice-card-live.txt", a11yRoot())
        }

        val closableBody = label(R.string.location_redacted_notice)
        hostCompose({
            ClosableNoticeCard(
                body = closableBody,
                actionLabel = label(R.string.location_redacted_notice_action),
                onAction = {},
                closeLabel = label(R.string.back),
                onClose = {},
            )
        }) {
            val node = awaitPoliteLiveRegion(closableBody)
            assertEquals(
                "可关闭通知条正文必须带 liveRegion=polite",
                View.ACCESSIBILITY_LIVE_REGION_POLITE,
                node.liveRegion,
            )
            saveTree("a11y-closable-notice-live.txt", a11yRoot())
        }
    }

    @Test
    fun photos_screen_connection_banners_carry_heading_and_live_region() {
        fun makeHolder() = TimelineSubscriptionHolder(
            scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
            currentPairing = { null },
            channelFor = { error("unused") },
        )

        hostCompose({
            PhotosScreen(
                holder = makeHolder(),
                connection = ConnectionState(ConnectionState.Status.PairingLost),
            )
        }) {
            val title = label(R.string.photos_lost_title)
            val node = awaitNode("照片页配对失效标题带 heading 与 liveRegion=polite") { n ->
                n.text?.toString() == title &&
                    n.liveRegion == View.ACCESSIBILITY_LIVE_REGION_POLITE &&
                    (Build.VERSION.SDK_INT < Build.VERSION_CODES.P || n.isHeading)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                assertTrue("配对失效卡片标题必须带 heading 语义", node.isHeading)
            }
            assertEquals(
                "配对失效卡片标题必须带 liveRegion=polite",
                View.ACCESSIBILITY_LIVE_REGION_POLITE,
                node.liveRegion,
            )
            saveTree("a11y-photos-lost-live.txt", a11yRoot())
        }

        hostCompose({
            PhotosScreen(
                holder = makeHolder(),
                connection = ConnectionState(ConnectionState.Status.Reconnecting),
            )
        }) {
            val node = awaitPoliteLiveRegion(label(R.string.photos_live_reconnecting))
            assertEquals(View.ACCESSIBILITY_LIVE_REGION_POLITE, node.liveRegion)
        }

        hostCompose({
            PhotosScreen(
                holder = makeHolder(),
                connection = ConnectionState(ConnectionState.Status.Offline),
            )
        }) {
            val node = awaitPoliteLiveRegion(label(R.string.photos_live_disconnected))
            assertEquals(View.ACCESSIBILITY_LIVE_REGION_POLITE, node.liveRegion)
        }
    }

    @Test
    fun viewer_notice_text_announces_via_polite_live_region() {
        val text = label(R.string.saved_to_gallery)
        hostCompose({ ViewerNoticeText(text) }) {
            val node = awaitPoliteLiveRegion(text)
            assertEquals(
                "看图/视频保存结果提示必须带 liveRegion=polite",
                View.ACCESSIBILITY_LIVE_REGION_POLITE,
                node.liveRegion,
            )
            saveTree("a11y-viewer-notice-live.txt", a11yRoot())
        }
    }

    @Test
    fun video_fetching_and_cover_error_announce_via_polite_live_region() {
        val fetchingText = testContext.getString(R.string.video_loading, 42)
        hostCompose({ VideoFetchingStatus(42) }) {
            val node = awaitPoliteLiveRegion(fetchingText)
            assertEquals(
                "视频下载进度必须带 liveRegion=polite",
                View.ACCESSIBILITY_LIVE_REGION_POLITE,
                node.liveRegion,
            )
        }

        val failedText = label(R.string.video_failed)
        hostCompose({
            VideoCover(
                cover = null,
                sizeLabel = "12 MB",
                notice = failedText,
                onPlay = {},
            )
        }) {
            val node = awaitPoliteLiveRegion(failedText)
            assertEquals(
                "视频封面失败提示必须带 liveRegion=polite",
                View.ACCESSIBILITY_LIVE_REGION_POLITE,
                node.liveRegion,
            )
            saveTree("a11y-video-cover-live.txt", a11yRoot())
        }
    }
}
