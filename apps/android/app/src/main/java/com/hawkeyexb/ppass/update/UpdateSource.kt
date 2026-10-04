// UPD-02 / UPD-12 (#624 / #650): 更新源依赖倒置 + 有序链式兜底。
//
// 历史：更新链路曾整条打在 GitHub 直连上（国内家人设备可达性差、慢；静默失败
// 会表现为「从来没检查到更新」）。#624 把来源抽成接口，#650 把「唯一实现」
// 换成「**有序列表**」：
//
//   1st  R2（https://p-pass-dl.hawkeye-xb.com）—— 国内可达，与官网下载同一条链路
//   2nd  GitHub —— 原 URL 原样保留，作为兜底（R2 被墙/故障时自动落回来）
//
// UPD-13 (#660)：stable 读的是**分端清单** `manifest-android.json`（只含 android
// 条目、顶层 version 是**本端**版本号）——这样「只有 macOS 变更」的那批不会把
// 安卓用户叫去更新。test 通道仍是 `manifest.json`（滚动 prerelease，单一来源）。
//
// 为什么不是单点：单点源只是把「可达性」从一个单点换成另一个单点；链式让**源本身
// 可替换**，且切换不需要任何运维动作（R2 挂了客户端自己会试 GitHub）。
// 为什么保留 GitHub 那一项：旧客户端一直打的就是它，它必须继续有效。
//
// 安全语义**不因换源而降**：manifest 自带 sha256 + minisign 签名（我们自己的公钥），
// R2 只是搬运工——被篡改的包照样在校验闸被拒（见 ApkVerifier / MinisignVerifier）。
//
// 切换纪律（红线，UpdateCheckerTest 看守）：stable 的候选列表与每一项的确切 URL
// 都被测试锁住——增删/重排都必须同时改测试，不允许静默漂移。
package com.hawkeyexb.ppass.update

/** R2 公共域（与 `.github/workflows/mirror-latest.yml` 的 PUBLIC_BASE 同源）。 */
const val R2_PUBLIC_BASE: String = "https://p-pass-dl.hawkeye-xb.com"

/**
 * 更新源：给一个通道，产出**按优先级排列**的 manifest URL 列表。实现必须是无副作用纯查询。
 *
 * [manifestUrls] 是主契约（有序候选）；[manifestUrl] 是单项源的便利访问（默认取首项）。
 */
interface UpdateSource {
    /** 日志用标识（不进 UI、不落盘）。 */
    val id: String

    /** 有序候选：逐项尝试，前一项不给出结论才落到下一项。 */
    fun manifestUrls(channel: UpdateChannel): List<String>

    /** 首选项。空列表（该源不服务这个通道）时返回空串。 */
    fun manifestUrl(channel: UpdateChannel): String = manifestUrls(channel).firstOrNull().orEmpty()
}

/**
 * GitHub 直链实现（UPD-01/REL-02/REL-07 的语义原样继承，现为链式第 2 项）：
 *  - stable 恒等于 GitHub `releases/latest/download` 原 URL——GitHub latest
 *    只认已发布的正式 release，**人工 publish 就是验收后的发布动作**
 *    （REL-02 卡面红线，UpdateCheckerTest 的 URL 锁测试继续看守）。
 *  - test 走滚动 prerelease `test-channel` 的静态资产——不调 GitHub API，
 *    没有匿名限流（REL-07）。
 */
object GitHubUpdateSource : UpdateSource {
    override val id: String = "github"

    override fun manifestUrls(channel: UpdateChannel): List<String> = listOf(
        when (channel) {
            UpdateChannel.Stable ->
                "https://github.com/hawkeye-xb/P-Pass/releases/latest/download/manifest-android.json"
            UpdateChannel.Test ->
                "https://github.com/hawkeye-xb/P-Pass/releases/download/test-channel/manifest.json"
        },
    )
}

/**
 * R2/自有域实现（#650，链式第 1 项）。**只服务 stable**：
 * test 通道是 GitHub 上的滚动 prerelease，R2 上没有对应对象——把 R2 放进 test 的
 * 候选里只会多一次 404（而 404 在语义上是「这个源没有」），所以直接不提供。
 */
object R2UpdateSource : UpdateSource {
    override val id: String = "r2"

    override fun manifestUrls(channel: UpdateChannel): List<String> =
        if (channel == UpdateChannel.Stable) listOf("$R2_PUBLIC_BASE/manifest-android.json") else emptyList()
}

/** 链式源：把若干源拼成一个有序候选列表。 */
class FallbackUpdateSource(private val sources: List<UpdateSource>) : UpdateSource {
    override val id: String = sources.joinToString("->") { it.id }

    override fun manifestUrls(channel: UpdateChannel): List<String> =
        sources.flatMap { it.manifestUrls(channel) }
}

/**
 * 当前生效的更新源——**全仓唯一的切换点**（UPD-02 卡面语义）。
 *
 * 现为 R2 → GitHub 链式。要整体回滚成「纯 GitHub」：把下面这行改回
 * `GitHubUpdateSource` 并**发一个版本**（切换点编译进包，做不到服务端热切）；
 * 但通常不需要——R2 不可达时客户端会自动落到 GitHub。
 */
fun defaultUpdateSource(): UpdateSource =
    FallbackUpdateSource(listOf(R2UpdateSource, GitHubUpdateSource))
