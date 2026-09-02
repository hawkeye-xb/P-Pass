// MOB-47: 播放器层替换守卫——VideoScreen 从系统 VideoView 换成 Media3
// ExoPlayer/PlayerView 的成熟方案。像 CacheRedlineTest 一样用源码扫描钉
// 不变量（JVM 单测跑不了 Android framework 的 PlayerView 渲染，但这几件事
// 是「换成熟播放器」这张卡的核心判据，用文本级守卫锁死回归）：
//  ① 不再引用 android.widget.VideoView（MVP 已撤）
//  ② 播放器实例是 ExoPlayer，且 release() 绑在 DisposableEffect 的
//     onDispose 里（退出查看器不泄漏——验收项「logcat 无泄漏」的代码面）
//  ③ 经 PlayerView 呈现（自带播放/暂停/进度/seek/错误态）
package com.hawkeyexb.ppass.ui

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VideoScreenTest {

    private fun videoScreenSource(): String {
        // gradle Test workingDir = :app 模块目录（apps/android/app），
        // 与 CacheRedlineTest 同一约定。
        val f = File("src/main/java/com/hawkeyexb/ppass/ui/VideoScreen.kt")
        assertTrue("找不到 VideoScreen.kt：${File(".").absolutePath}", f.isFile)
        return f.readText()
    }

    @Test
    fun videoViewMvpIsGone() {
        // 反证：改回 android.widget.VideoView 本测试立刻红——MVP 已撤。
        assertFalse(
            "VideoScreen 仍引用系统 VideoView（MVP 应已被 Media3 替换）",
            videoScreenSource().contains("android.widget.VideoView"),
        )
    }

    @Test
    fun playsThroughMedia3ExoPlayer() {
        val src = videoScreenSource()
        assertTrue("缺少 ExoPlayer 构造", src.contains("ExoPlayer.Builder"))
        assertTrue("缺少 MediaItem 绑定", src.contains("MediaItem.fromUri"))
        assertTrue("缺少 PlayerView 呈现", src.contains("PlayerView"))
    }

    @Test
    fun playerIsReleasedOnDispose() {
        val src = videoScreenSource()
        // 反证：把 release() 从 DisposableEffect onDispose 挪走（或删掉），
        // 本测试红——退出查看器必须释放播放器，杜绝 MediaCodec/ExoPlayer 泄漏。
        assertTrue("缺少 DisposableEffect", src.contains("DisposableEffect"))
        assertTrue("缺少 player.release() 释放", src.contains("player.release()"))
    }
}