// UPD-03（#580）：manifest notes → 更新弹窗正文（纯函数，UpdateNotesTest 锁行为）。
//
// #741 起流水线给的是手写的用户更新说明（release/notes/**，CI lint 把关，
// 规则见 docs/release-notes-rules.md）：notes = 中文，notes_i18n = {zh, en}。
// 这里做三件事：
//   1. 按 App 当前语言选一份（[pickUpdateNotes]）：zh 系取 zh，其它取 en；
//      取不到回落 notes，再回落默认文案（调用方）。
//   2. 拒收（[isSafeUpdateNotes]）：清单没签名，文字可能被篡改。只要含网址/域名、
//      邮箱、电话样式、Unicode 双向控制符、零宽或其它控制字符，就整段丢弃、
//      显示默认文案——不尝试另一种语言，也不做部分清洗。判的是**原文**
//      （清洗会把 [t](url) 变成 t，先清洗再判就漏了）。
//   3. 清洗兜底（[userFacingNotes]）：老 release 的 manifest、手工修过的 manifest
//      里仍可能是 markdown / 构建台账。只展示「去掉 markdown 记号、截在句或词边界」
//      的一段短文；清洗后没剩可读内容 ⇒ 返回 ""，由调用方回落默认文案。
// 纯文本渲染，不做链接识别。不依赖 R / Context，JVM 单测可直接跑。
package com.hawkeyexb.ppass.update

/** 弹窗正文上限（字符数，不含截断后追加的「…」）。沿用原 take(200) 的量级。 */
const val UPDATE_NOTES_MAX_CHARS = 200

private val LINK = Regex("""!?\[([^\]]*)]\([^)]*\)""")
private val ISSUE_REF = Regex("""\s*[（(]\s*#\d+(?:\s*[、,，]\s*#\d+)*\s*[)）]""")
private val EMPHASIS = Regex("""\*\*|__|~~|`+""")
private val SINGLE_EMPHASIS = Regex("""(^|[\s(（])[*_](\S(?:.*?\S)?)[*_](?=$|[\s.,;:!?)）。，；：！？])""")
private val HEADING = Regex("""^#{1,6}\s*""")
private val QUOTE = Regex("""^(?:>\s?)+""")
private val BULLET = Regex("""^(?:[-*+]|\d+[.)])\s+""")
private val RULE = Regex("""^(?:-{3,}|\*{3,}|_{3,})$""")
private val READABLE = Regex("""[\p{L}\p{N}]""")
private val ESCAPE = Regex("""\\([\\`*_{}\[\]()#+\-.!<>|])""")

/** 句末标点（中英）：优先在这里断。 */
private const val SENTENCE_END = "。！？；!?;\n"

/** 次级边界：逗号顿号、冒号、空白（英文词边界）。 */
private const val SOFT_BREAK = "，、,：: \t"

/**
 * 把 manifest 的 notes 变成给用户看的短文本。
 * @return 清洗 + 截断后的纯文本；没有可读内容时返回 ""（调用方显示默认文案）。
 */
fun userFacingNotes(raw: String, maxChars: Int = UPDATE_NOTES_MAX_CHARS): String {
    val lines = raw.replace("\r\n", "\n").replace('\r', '\n').lines().mapNotNull { line ->
        var l = line.trim()
        if (RULE.matches(l)) return@mapNotNull null
        l = HEADING.replace(l, "")
        l = QUOTE.replace(l, "")
        l = BULLET.replace(l, "· ")
        l = LINK.replace(l) { it.groupValues[1] }
        l = ISSUE_REF.replace(l, "")
        l = EMPHASIS.replace(l, "")
        l = SINGLE_EMPHASIS.replace(l) { it.groupValues[1] + it.groupValues[2] }
        l = ESCAPE.replace(l) { it.groupValues[1] } // 反斜杠转义：\< → <
        l.trim()
    }
    val text = lines.joinToString("\n").replace(Regex("\n{3,}"), "\n\n").trim()
    if (!READABLE.containsMatchIn(text)) return ""
    return truncateAtBoundary(text, maxChars)
}

/**
 * 不超过 [maxChars] 字符；超了就截在最后一个句末标点之后，没有句末标点就退到
 * 逗号/空白等次级边界，都没有才硬切。截断后追加「…」。边界太靠前（不到上限
 * 一半）时不采用，免得只剩半句话。
 */
internal fun truncateAtBoundary(text: String, maxChars: Int): String {
    if (text.length <= maxChars) return text
    val window = text.substring(0, maxChars)
    val minKeep = maxChars / 2
    val sentence = window.indexOfLast { it in SENTENCE_END }
    val cut = when {
        sentence + 1 >= minKeep -> sentence + 1
        else -> {
            val soft = window.indexOfLast { it in SOFT_BREAK }
            if (soft >= minKeep) soft else maxChars
        }
    }.let { if (it in 1 until text.length && text[it - 1].isHighSurrogate()) it - 1 else it }
    return text.substring(0, cut).trimEnd().trimEnd('，', '、', ',', '：', ':', '；', ';') + "…"
}

// ── #741：按语言选取 + 拒收 ──────────────────────────────────────────

/**
 * 网址：协议头、www.、以及会被系统当链接处理的 scheme。
 * 边界用 ASCII 后顾而不是 \b：Android 的 ICU 正则把汉字算作单词字符，
 * 「请到https://…」这种贴着中文的写法用 \b 会漏判（JVM 21 的 \b 是 ASCII 语义，单测测不出差别）。
 */
private val REJECT_URL = Regex(
    """(?<![a-z0-9+.\-])[a-z][a-z0-9+.\-]*://|(?<![a-z0-9])www\.|(?<![a-z0-9])(?:mailto|tel|sms|market|intent|javascript|file):""",
    RegexOption.IGNORE_CASE,
)

/** 域名样式：至少一个点、顶级段至少 2 个字母（版本号 0.9.10 不命中）。 */
private val REJECT_DOMAIN = Regex(
    """(?<![a-z0-9\-])(?:[a-z0-9](?:[a-z0-9\-]*[a-z0-9])?\.)+[a-z]{2,}(?![a-z0-9\-])""",
    RegexOption.IGNORE_CASE,
)

/** 邮箱（含全角 ＠）。 */
private val REJECT_EMAIL = Regex("""[A-Za-z0-9._%+\-]+[@＠][A-Za-z0-9\-]+""")

/** 电话样式：7 位及以上数字，中间可夹空格 / 连字符 / 括号。 */
private val REJECT_PHONE = Regex("""[+＋]?\d(?:[\s\-()]*\d){6,}""")

// 以下三条用正则引擎的 \x{…} 码点写法：源码字符串里不出现这些字符本身
// （Android lint 的 BidiSpoofing / ByteOrderMark 会把字面量里的它们判为错误）。

/** Unicode 双向控制符（Trojan Source 类显示欺骗）。 */
private val REJECT_BIDI =
    Regex("""[\x{202A}-\x{202E}\x{2066}-\x{2069}\x{200E}\x{200F}\x{061C}]""")

/** 零宽 / 不可见字符（含 BOM）。 */
private val REJECT_ZERO_WIDTH = Regex("""[\x{200B}-\x{200D}\x{2060}-\x{2064}\x{FEFF}\x{180E}]""")

/** 其它控制字符。\t \n \r 放行：旧清单的 notes 里有正常换行。 */
private val REJECT_CONTROL =
    Regex("""[\x{0000}-\x{0008}\x{000B}\x{000C}\x{000E}-\x{001F}\x{007F}-\x{009F}]""")

private val REJECT_RULES = listOf(
    REJECT_URL, REJECT_DOMAIN, REJECT_EMAIL, REJECT_PHONE,
    REJECT_BIDI, REJECT_ZERO_WIDTH, REJECT_CONTROL,
)

/**
 * 说明原文是否可以展示。含网址/域名、邮箱、电话样式、双向控制符、零宽或控制字符
 * ⇒ false（调用方整段丢弃、显示默认文案）。
 */
fun isSafeUpdateNotes(raw: String): Boolean = REJECT_RULES.none { it.containsMatchIn(raw) }

/**
 * App 当前语言 → 说明语言键。zh 系（zh、zh-CN、zh-Hans-CN、zh-TW、zh_CN…）取 "zh"，
 * 其它一律 "en"。
 */
fun updateNotesLang(languageTag: String): String {
    val t = languageTag.trim().lowercase()
    return if (t == "zh" || t.startsWith("zh-") || t.startsWith("zh_")) "zh" else "en"
}

/** 选一份说明原文：notes_i18n[lang] 非空就用它，否则回落 notes（旧清单只有它）。 */
fun pickUpdateNotes(notesI18n: Map<String, String>, notes: String, lang: String): String =
    notesI18n[lang]?.takeIf { it.isNotBlank() } ?: notes

/**
 * 更新弹窗正文：按语言选取 → 拒收 → 清洗截断。
 * @return 要展示的纯文本；"" ⇒ 调用方显示默认文案（没有说明 / 被拒收 / 清洗后为空）。
 */
fun displayUpdateNotes(notesI18n: Map<String, String>, notes: String, languageTag: String): String {
    val raw = pickUpdateNotes(notesI18n, notes, updateNotesLang(languageTag))
    if (!isSafeUpdateNotes(raw)) return ""
    return userFacingNotes(raw)
}
