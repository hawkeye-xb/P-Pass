// UPD-02: 更新源依赖倒置。
//
// 为什么抽这一层：更新链路现在整条打在 GitHub 直连上（匿名限流 60/h/IP、
// 国内家人设备可达性差——静默失败让"从来没检查到更新"不可见）。切 R2 /
// 自有域是必然动作，但切的时候**一根手指都不许碰流程代码**——所以客户端
// 只依赖 [UpdateSource] 接口，GitHub 只是当前的唯一实现；将来新增
// R2UpdateSource 并改 [defaultUpdateSource] 一处，即完成切换。
package com.hawkeyexb.ppass.update

/** 更新源：给一个通道，产出 manifest URL。实现必须是无副作用纯查询。 */
interface UpdateSource {
    /** 日志用标识（不进 UI、不落盘）。 */
    val id: String

    fun manifestUrl(channel: UpdateChannel): String
}

/**
 * GitHub 直链实现（现状的承载者，UPD-01/REL-02/REL-07 的语义原样继承）：
 *  - stable 恒等于 GitHub `releases/latest/download` 原 URL——GitHub latest
 *    只认已发布的正式 release，**人工 publish 就是验收后的发布动作**
 *    （REL-02 卡面红线，UpdateCheckerTest 的 URL 锁测试继续看守）。
 *  - test 走滚动 prerelease `test-channel` 的静态资产——不调 GitHub API，
 *    没有匿名限流（REL-07）。
 */
object GitHubUpdateSource : UpdateSource {
    override val id: String = "github"

    override fun manifestUrl(channel: UpdateChannel): String = when (channel) {
        UpdateChannel.Stable ->
            "https://github.com/hawkeye-xb/P-Pass/releases/latest/download/manifest.json"
        UpdateChannel.Test ->
            "https://github.com/hawkeye-xb/P-Pass/releases/download/test-channel/manifest.json"
    }
}

/**
 * 当前生效的更新源——**全仓唯一的切换点**。
 * R2 就绪后在这里换成 R2UpdateSource（或构建期注入），其余代码零改动。
 */
fun defaultUpdateSource(): UpdateSource = GitHubUpdateSource
