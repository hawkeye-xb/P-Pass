// UPD-03（#580）：manifest notes → 更新弹窗正文（纯函数，UpdateNotesTest 锁行为）。
//
// 流水线侧已改为只给 CHANGELOG 本版小节的纯文本（tools/changelog-notes.mjs），
// 这里是兜底：老 release 的 manifest、手工修过的 manifest、或流水线回归时，
// notes 里仍可能是 markdown / 构建台账。弹窗只展示「去掉 markdown 记号、截在
// 句或词边界」的一段短文；清洗后没剩可读内容 ⇒ 返回 ""，由调用方回落默认文案。
// 不依赖 R / Context，JVM 单测可直接跑。
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
