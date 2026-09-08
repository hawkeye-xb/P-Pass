package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.proto.AssetMeta

/**
 * 查看器的页序快照。打开时固定当前过滤结果，时间线随后刷新不会让用户正在看的
 * 资产跳页；找不到被点击项则拒绝打开，不能沿用上一轮的陈旧索引。
 */
internal data class MediaViewerSession(
    val assets: List<AssetMeta>,
    val initialPage: Int,
) {
    init {
        require(assets.isNotEmpty()) { "media viewer requires at least one asset" }
        require(initialPage in assets.indices) { "initial page must point at an asset" }
    }

    companion object {
        fun open(assets: List<AssetMeta>, tappedHash: String): MediaViewerSession? {
            val initialPage = assets.indexOfFirst { it.hash == tappedHash }
            return initialPage.takeIf { it >= 0 }?.let { MediaViewerSession(assets, it) }
        }
    }
}

/** `BackHandler` 只在查看器打开时消费系统返回；根页面必须交还给 Android。 */
internal enum class ViewerBackAction { CloseViewer, DelegateToSystem }

internal fun viewerBackAction(viewerOpen: Boolean): ViewerBackAction =
    if (viewerOpen) ViewerBackAction.CloseViewer else ViewerBackAction.DelegateToSystem

/**
 * 下拉关闭仅允许在 Telephoto 处于最小缩放时触发。阈值由 UI 层使用 dp 转成像素，
 * 这里保持为纯函数，使「缩放后下拉绝不关页」可在 JVM 单测中锁定。
 */
internal fun canDismissFromPull(zoomFraction: Float, dragPx: Float, thresholdPx: Float): Boolean =
    zoomFraction <= 0f && dragPx >= thresholdPx
