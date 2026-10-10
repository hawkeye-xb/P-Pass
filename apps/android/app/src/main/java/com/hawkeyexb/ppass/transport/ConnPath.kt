// DIAG-A: 手机侧连接诊断——路径分类与一次探测的逐阶段记录。
//
// 分类口径与桌面 `crates/transport/src/conninfo.rs` 的 PathKind 完全一致（lan / direct / relay）：
// 选中的路径优先，没有选中就取第一条；relay 路径是 relay；IP 路径按对端地址是否可路由分 lan / direct。
// 纯函数，不碰 iroh 类型，JVM 单测直接喂字符串。
package com.hawkeyexb.ppass.transport

/** iroh 无关的一条路径快照（来自 `Connection.paths()`）。 */
data class PathFacts(val selected: Boolean, val relay: Boolean, val remoteAddr: String, val rttMs: Long)

/** 与 conninfo.rs 的 `PathKind` 同名同义；`none` = 连接上没有任何路径。 */
enum class PathKind(val wire: String) { LAN("lan"), DIRECT("direct"), RELAY("relay"), NONE("none") }

data class PathVerdict(val kind: PathKind, val remoteAddr: String?, val rttMs: Long)

fun classifyPaths(paths: List<PathFacts>): PathVerdict {
    val p = paths.firstOrNull { it.selected } ?: paths.firstOrNull() ?: return PathVerdict(PathKind.NONE, null, 0)
    val kind = when {
        p.relay -> PathKind.RELAY
        isLanAddr(p.remoteAddr) -> PathKind.LAN
        else -> PathKind.DIRECT
    }
    return PathVerdict(kind, p.remoteAddr, p.rttMs)
}

/**
 * `ip:port` / `[v6]:port` / 裸 IP → 是否不可路由（私网 / 回环 / 链路本地 / ULA）。解析不了的一律当
 * 可路由（direct）——只做字面量解析，绝不走 DNS。
 */
fun isLanAddr(addr: String): Boolean {
    val host = hostOf(addr) ?: return false
    parseV4(host)?.let { (a, b) ->
        return a == 10 || (a == 172 && b in 16..31) || (a == 192 && b == 168) || a == 127 || (a == 169 && b == 254)
    }
    val lower = host.lowercase()
    if (!lower.contains(':')) return false
    if (lower == "::1") return true
    val first = lower.substringBefore(':').ifEmpty { "0" }.toIntOrNull(16) ?: return false
    return (first and 0xffc0) == 0xfe80 || (first and 0xfe00) == 0xfc00
}

private fun hostOf(addr: String): String? {
    val a = addr.trim()
    if (a.isEmpty()) return null
    if (a.startsWith("[")) return a.substring(1).substringBefore(']')
    return if (a.count { it == ':' } == 1) a.substringBefore(':') else a
}

private fun parseV4(host: String): Pair<Int, Int>? {
    val parts = host.split('.')
    if (parts.size != 4) return null
    val nums = parts.map { it.toIntOrNull()?.takeIf { n -> n in 0..255 } ?: return null }
    return nums[0] to nums[1]
}

/** 失败时 iroh 手里对端的地址（`Endpoint.remoteAddr`）。只进 [CallTrace.render]，按类别输出。 */
data class KnownAddr(val relay: String?, val direct: List<String>)

/**
 * #548：地址 → 类别，不含原文。`v4:lan` / `v4:public` / `v6:lan` / `v6:public`；不是 IP 字面量 → `other`。
 * lan / public 与 [isLanAddr] 同口径（私网 / 回环 / 链路本地 / ULA 为 lan）。
 */
fun addrClass(addr: String): String {
    val host = hostOf(addr) ?: return "other"
    val family = when {
        parseV4(host) != null -> "v4"
        host.contains(':') && host.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' || it == ':' || it == '.' } -> "v6"
        else -> return "other"
    }
    return family + if (isLanAddr(addr)) ":lan" else ":public"
}

/** 一组地址 → `[v4:lan,v6:public]`（顺序保留，个数即直连候选数）。 */
fun addrClasses(addrs: List<String>): String = addrs.joinToString(",", "[", "]") { addrClass(it) }

/**
 * #548：relay URL → `n0`（n0 的公共 relay，`*.iroh.link`，地域码只到大洲级）/ `custom`（自建 relay，
 * 域名能识别人）/ `-`（没有）。白名单与桌面脱敏规则（redact-vectors.json）一致。
 */
fun relayClass(url: String?): String {
    if (url.isNullOrBlank()) return "-"
    val host = url.substringAfter("://").takeWhile { it !in "/:?#[]" }.trimEnd('.').lowercase()
    return if (host == "iroh.link" || host.endsWith(".iroh.link")) "n0" else "custom"
}

/**
 * 一次 `callTraced` 的逐阶段记录。时间都是从调用开始算的毫秒；没走到那一步就是 null。
 * - [homeRelayAtStart]：开始时本端 endpoint 地址里的 relay（null = 还没有 home relay）。
 * - [onlineAfterMs]：本端 `online()`（home relay 连上）在这次调用期间何时返回；0 附近 = 开始时已 online。
 * - [connectMs]：`connect()` 返回（QUIC 握手完成）；[roundTripMs]：收到回复。
 * - [peerKnownAddr]：失败时 iroh 手里对端的地址（relay + 直连地址）——看直连地址是不是过期了。
 *
 * #548：[render] 进 logcat，只输出类别，不输出原文——地址只给「v4 / v6 × lan / public」，relay 只给
 * 「n0（公共 relay）/ custom（自建，域名能识别人）」。排障要的是「有没有直连地址、是不是公网、走哪类
 * relay」，不是具体的 IP 和域名。原生层异常文本（[errorMessage]）原样交出，由日志出口 PLog 统一脱敏。
 */
data class CallTrace(
    val method: String,
    val tokenRelay: String?,
    val tokenDirectAddrs: List<String>,
    val homeRelayAtStart: String?,
    val onlineAfterMs: Long?,
    val connectMs: Long?,
    val roundTripMs: Long?,
    val totalMs: Long,
    val path: PathVerdict?,
    val pathCount: Int,
    val errorClass: String?,
    val errorKind: String?,
    val errorMessage: String?,
    val peerKnownAddr: KnownAddr?,
) {
    fun render(): String = buildString {
        append("method=").append(method)
        append(" totalMs=").append(totalMs)
        append(" connectMs=").append(connectMs ?: "-")
        append(" rpcMs=").append(if (connectMs != null && roundTripMs != null) roundTripMs - connectMs else "-")
        append(" online=").append(if (homeRelayAtStart != null) "yes" else "no")
        append(" homeRelay=").append(relayClass(homeRelayAtStart))
        append(" onlineAfterMs=").append(onlineAfterMs ?: "never")
        append(" path=").append(path?.kind?.wire ?: "-")
        path?.let {
            val remote = it.remoteAddr?.let { a -> if (it.kind == PathKind.RELAY) relayClass(a) else addrClass(a) }
            append(" remote=").append(remote ?: "-").append(" rttMs=").append(it.rttMs)
        }
        append(" paths=").append(pathCount)
        append(" tokenRelay=").append(relayClass(tokenRelay))
        append(" tokenDirect=").append(addrClasses(tokenDirectAddrs))
        if (errorClass != null) {
            append(" error=").append(errorClass)
            append(" kind=").append(errorKind ?: "-")
            append(" msg=").append(errorMessage ?: "-")
            append(" peerKnown=").append(
                peerKnownAddr?.let { "relay:${relayClass(it.relay)} direct:${addrClasses(it.direct)}" } ?: "-",
            )
        }
    }
}
