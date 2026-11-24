package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.proto.AssetMeta

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

internal enum class ViewerBackAction { CloseViewer, DelegateToSystem }

internal fun viewerBackAction(viewerOpen: Boolean): ViewerBackAction =
    if (viewerOpen) ViewerBackAction.CloseViewer else ViewerBackAction.DelegateToSystem

internal fun canDismissFromPull(zoomFraction: Float, dragPx: Float, thresholdPx: Float): Boolean =
    zoomFraction <= 0f && dragPx >= thresholdPx

internal const val VIEWER_PREFETCH_NEIGHBOUR_PAGES = 1

internal data class ViewerChromeSpec(
    val closeDescriptionRes: Int = R.string.back,
    val actionsEnabled: Boolean,
    val minActionHeightDp: Int = 44,
)

internal fun viewerChromeSpecOf(busy: Boolean): ViewerChromeSpec =
    ViewerChromeSpec(actionsEnabled = !busy)
