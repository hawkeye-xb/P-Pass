// #548：Android 日志的统一脱敏（按值的形状，不按字段名）。
//
// 这是 `crates/daemon/src/redact.rs` 里 `redact()`（规则 0–4）的 Kotlin 移植——桌面 daemon 的
// 日志写入器（`log_guard`）在落盘前只过这一个函数，这里是 Android 端同一位置的同一件事：
// [PLog] 是 App 写 logcat 的唯一出口，每一行写出前都过 [redact]。导出件专用的路径 / 文件名规则
// （`redact_export`）不属于日志写入器的口径，没有移植。
//
// 口径锁定：JVM 单测 `RedactVectorsTest` 跑与 daemon / 桌面壳 / transport 同一份
// `assets/privacy/redact-vectors.json`（exact + keep 两段）。改规则先改向量，四份实现一起过。
//
// 移植约定：
// - 字符类一律是显式 ASCII（对应 Rust 的 `is_ascii_*`）；Kotlin 的 isLetterOrDigit 认 Unicode，不能用。
// - IP 只做字面量解析，逐步复刻 Rust `core::net` 解析器（IPv4 拒前导 0、IPv6 允许尾部内嵌 IPv4、
//   `::` 至少代表一组）。绝不用 InetAddress——它对不认识的字面量会去查 DNS。
package com.hawkeyexb.ppass.log

object Redact {

    /** 统一入口：字节数组 → IP → URL 主机名 → 长串。幂等。 */
    fun redact(s: String): String = maskTokens(maskUrlHosts(maskIps(maskByteArrays(s))))

    // ── 规则 0：十进制字节数组（`[234, 74, 108, …]`）──────────────────────

    fun maskByteArrays(s: String): String {
        val out = StringBuilder(s.length)
        var rest = s
        while (true) {
            val open = rest.indexOf('[')
            if (open < 0) break
            out.append(rest, 0, open)
            val after = rest.substring(open + 1)
            val close = after.indexOf(']')
            var count = -1
            if (close >= 0) {
                val items = after.substring(0, close).split(',').map { it.trim() }
                val allBytes = items.all { t -> t.isNotEmpty() && t.length <= 3 && (parseU16(t) ?: 256) <= 255 }
                if (items.size >= 16 && allBytes) count = items.size
            }
            if (count >= 0) {
                out.append("[<bytes:").append(count).append(">]")
                rest = after.substring(close + 1)
            } else {
                out.append('[')
                rest = after
            }
        }
        out.append(rest)
        return out.toString()
    }

    /** Rust `str::parse::<u16>`：可选 `+`，其后至少一位十进制数字。 */
    private fun parseU16(t: String): Int? {
        val d = if (t.startsWith('+')) t.substring(1) else t
        if (d.isEmpty() || !d.all(::isAsciiDigit)) return null
        return d.toIntOrNull()?.takeIf { it <= 0xffff }
    }

    // ── 规则 1：公网 IP ───────────────────────────────────────────────

    fun maskIps(s: String): String {
        val out = StringBuilder(s.length)
        var i = 0
        while (i < s.length) {
            if (!isIpChar(s[i])) {
                out.append(s[i])
                i++
                continue
            }
            var j = i
            while (j < s.length && isIpChar(s[j])) j++
            val prev = if (i > 0) s[i - 1] else null
            val next = if (j < s.length) s[j] else null
            out.append(maskIpRun(s.substring(i, j), prev, next))
            i = j
        }
        return out.toString()
    }

    private fun maskIpRun(run: String, prev: Char?, next: Char?): String {
        // 紧贴着字母数字的不是独立的地址（`noq_proto::connection`、`0.58s`、`T01:49:50.5`）。
        if (next != null && isWord(next)) return run
        val lead = run.length - run.trimStart(':').length
        val coreTrimmed = run.substring(lead).trimEnd('.', ':')
        val trail = run.length - lead - coreTrimmed.length
        val candidates = listOf(Triple(0, run, 0), Triple(lead, coreTrimmed, trail))
        for ((ld, core, tr) in candidates) {
            val effectivePrev = if (ld > 0) ':' else prev
            if ((effectivePrev != null && isWord(effectivePrev)) || core.isEmpty()) continue
            val rep = classifyIp(core) ?: continue
            return run.substring(0, ld) + rep + run.substring(run.length - tr)
        }
        return run
    }

    private fun classifyIp(core: String): String? {
        parseIpv6(core)?.let { return if (v6IsPublic(it)) "<ipv6:public>" else core }
        parseIpv4(core)?.let { return if (v4IsPublic(it)) "<ipv4:public>" else core }
        val colon = core.lastIndexOf(':')
        if (colon < 0) return null
        val addr = core.substring(0, colon)
        val port = core.substring(colon + 1)
        if (port.isEmpty() || port.length > 5 || !port.all(::isAsciiDigit)) return null
        val v4 = parseIpv4(addr) ?: return null
        return if (v4IsPublic(v4)) "<ipv4:public>:$port" else core
    }

    private fun v4IsPublic(o: IntArray): Boolean {
        val private = o[0] == 10 || (o[0] == 172 && (o[1] and 0xf0) == 16) || (o[0] == 192 && o[1] == 168)
        val loopback = o[0] == 127
        val linkLocal = o[0] == 169 && o[1] == 254
        val unspecified = o.all { it == 0 }
        val broadcast = o.all { it == 255 }
        val multicast = (o[0] and 0xf0) == 224
        val cgnat = o[0] == 100 && (o[1] and 0xc0) == 64
        return !(private || loopback || linkLocal || unspecified || broadcast || multicast || cgnat)
    }

    private fun v6IsPublic(seg: IntArray): Boolean {
        val mapped = (0..4).all { seg[it] == 0 } && seg[5] == 0xffff
        if (mapped) {
            return v4IsPublic(intArrayOf(seg[6] shr 8, seg[6] and 0xff, seg[7] shr 8, seg[7] and 0xff))
        }
        val loopback = (0..6).all { seg[it] == 0 } && seg[7] == 1
        val unspecified = seg.all { it == 0 }
        val multicast = (seg[0] and 0xff00) == 0xff00
        val uniqueLocal = (seg[0] and 0xfe00) == 0xfc00
        val linkLocal = (seg[0] and 0xffc0) == 0xfe80
        return !(loopback || unspecified || multicast || uniqueLocal || linkLocal)
    }

    /** Rust `Ipv4Addr::from_str`：四段十进制，每段 1–3 位、≤255、无前导 0。返回四个八位组。 */
    internal fun parseIpv4(s: String): IntArray? {
        val p = IpParser(s)
        val v = p.readIpv4() ?: return null
        return if (p.done()) v else null
    }

    /** Rust `Ipv6Addr::from_str`（无方括号、无 zone）。返回八个 16 位段。 */
    internal fun parseIpv6(s: String): IntArray? {
        val p = IpParser(s)
        val v = p.readIpv6() ?: return null
        return if (p.done()) v else null
    }

    /** 逐步复刻 `core::net::parser::Parser`：贪心、原子回滚、不回溯其它分支。 */
    private class IpParser(private val s: String) {
        var pos = 0

        fun done() = pos == s.length

        private inline fun <T> atomically(block: () -> T?): T? {
            val saved = pos
            val r = block()
            if (r == null) pos = saved
            return r
        }

        private fun readGivenChar(c: Char): Unit? =
            if (pos < s.length && s[pos] == c) { pos++; Unit } else null

        private fun digitOf(c: Char, radix: Int): Int? = when {
            c in '0'..'9' -> c - '0'
            radix == 16 && c in 'a'..'f' -> c - 'a' + 10
            radix == 16 && c in 'A'..'F' -> c - 'A' + 10
            else -> null
        }

        private fun readNumber(radix: Int, maxDigits: Int, allowZeroPrefix: Boolean, max: Int): Int? = atomically {
            var result = 0
            var count = 0
            val leadingZero = pos < s.length && s[pos] == '0'
            var ok = true
            while (pos < s.length) {
                val d = digitOf(s[pos], radix) ?: break
                pos++
                result = result * radix + d
                count++
                if (result > max || count > maxDigits) { ok = false; break }
            }
            when {
                !ok || count == 0 -> null
                !allowZeroPrefix && leadingZero && count > 1 -> null
                else -> result
            }
        }

        private fun <T> readSeparator(sep: Char, index: Int, inner: () -> T?): T? = atomically {
            if (index > 0 && readGivenChar(sep) == null) null else inner()
        }

        fun readIpv4(): IntArray? = atomically {
            val out = IntArray(4)
            var ok = true
            for (i in 0 until 4) {
                val n = readSeparator('.', i) { readNumber(10, 3, false, 255) }
                if (n == null) { ok = false; break }
                out[i] = n
            }
            if (ok) out else null
        }

        /** 返回 (读到的段数, 是否以内嵌 IPv4 结尾)。 */
        private fun readGroups(groups: IntArray, limit: Int): Pair<Int, Boolean> {
            for (i in 0 until limit) {
                if (i < limit - 1) {
                    val v4 = readSeparator(':', i) { readIpv4() }
                    if (v4 != null) {
                        groups[i] = (v4[0] shl 8) or v4[1]
                        groups[i + 1] = (v4[2] shl 8) or v4[3]
                        return (i + 2) to true
                    }
                }
                val g = readSeparator(':', i) { readNumber(16, 4, true, 0xffff) } ?: return i to false
                groups[i] = g
            }
            return limit to false
        }

        fun readIpv6(): IntArray? = atomically {
            val head = IntArray(8)
            val (headSize, headIpv4) = readGroups(head, 8)
            when {
                headSize == 8 -> head
                headIpv4 -> null
                readGivenChar(':') == null || readGivenChar(':') == null -> null
                else -> {
                    val tail = IntArray(7)
                    val (tailSize, _) = readGroups(tail, 8 - (headSize + 1))
                    for (k in 0 until tailSize) head[8 - tailSize + k] = tail[k]
                    head
                }
            }
        }
    }

    // ── 规则 2：URL 主机名 ────────────────────────────────────────────

    /** 白名单：n0 的 relay / 发现服务（`*.iroh.link`）与 GitHub（更新检查）。其余一律 `<host>`。 */
    private val ALLOWED_HOSTS = listOf("iroh.link", "github.com", "githubusercontent.com")
    private val SCHEMES = listOf("https://", "http://", "wss://", "ws://")
    private const val HOST_TERMINATORS = "/:?#<>\"'()[]{},;&\\"

    private fun hostAllowed(host: String): Boolean {
        val h = asciiLower(host.trimEnd('.'))
        return ALLOWED_HOSTS.any { d -> h == d || h.endsWith(".$d") }
    }

    fun maskUrlHosts(s: String): String {
        val out = StringBuilder(s.length)
        var rest = s
        while (true) {
            var bestPos = -1
            var bestLen = 0
            for (scheme in SCHEMES) {
                val p = rest.indexOf(scheme)
                if (p >= 0 && (bestPos < 0 || p < bestPos || (p == bestPos && scheme.length < bestLen))) {
                    bestPos = p
                    bestLen = scheme.length
                }
            }
            if (bestPos < 0) {
                out.append(rest)
                return out.toString()
            }
            out.append(rest, 0, bestPos + bestLen)
            val after = rest.substring(bestPos + bestLen)
            var hostLen = after.indexOfFirst { it.isWhitespace() || it in HOST_TERMINATORS }
            if (hostLen < 0) hostLen = after.length
            val host = after.substring(0, hostLen)
            out.append(if (host.isEmpty() || hostAllowed(host)) host else "<host>")
            rest = after.substring(hostLen)
        }
    }

    // ── 规则 3 + 4：长不透明串 / 长 hex 串只留前 8 位 ─────────────────────

    private const val MASK = "…<masked>"

    private fun isTokenChar(c: Char) = isAsciiAlnum(c) || c == '_' || c == '-'

    private fun isOpaque(run: String): Boolean =
        run.length >= 32 && run.count(::isAsciiDigit) >= 2 && run.count(::isAsciiAlpha) >= 8

    fun maskTokens(s: String): String {
        val out = StringBuilder(s.length)
        var i = 0
        while (i < s.length) {
            if (!isTokenChar(s[i])) {
                out.append(s[i])
                i++
                continue
            }
            var j = i
            while (j < s.length && isTokenChar(s[j])) j++
            val run = s.substring(i, j)
            val allHex = run.all(::isAsciiHex)
            if (isOpaque(run) || (allHex && run.length >= 24)) {
                out.append(run, 0, 8).append(MASK)
            } else {
                out.append(maskHexSubruns(run))
            }
            i = j
        }
        return out.toString()
    }

    /** 不够"不透明"的串里嵌着的 ≥24 位 hex（`node_<24hex>`）仍然要打码。 */
    private fun maskHexSubruns(run: String): String {
        val out = StringBuilder(run.length)
        var i = 0
        while (i < run.length) {
            if (!isAsciiHex(run[i])) {
                out.append(run[i])
                i++
                continue
            }
            var j = i
            while (j < run.length && isAsciiHex(run[j])) j++
            if (j - i >= 24) out.append(run, i, i + 8).append(MASK) else out.append(run, i, j)
            i = j
        }
        return out.toString()
    }

    // ── ASCII 字符类（对应 Rust 的 is_ascii_*）──────────────────────────

    private fun isAsciiDigit(c: Char) = c in '0'..'9'
    private fun isAsciiAlpha(c: Char) = c in 'a'..'z' || c in 'A'..'Z'
    private fun isAsciiAlnum(c: Char) = isAsciiDigit(c) || isAsciiAlpha(c)
    private fun isAsciiHex(c: Char) = isAsciiDigit(c) || c in 'a'..'f' || c in 'A'..'F'
    private fun isIpChar(c: Char) = isAsciiHex(c) || c == ':' || c == '.'
    private fun isWord(c: Char) = isAsciiAlnum(c) || c == '_'
    private fun asciiLower(s: String) = buildString(s.length) { s.forEach { append(if (it in 'A'..'Z') it + 32 else it) } }
}
