// #1072 acceptance 4 (E1 gate): the phone decides on the desktop's `reason` only. No production
// source under app/src/main may carry a diag `err.*` key literal or read the retired `msg_key`.
// The scanner's own self-test proves it would catch the old shapes.
package com.hawkeyexb.ppass

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NoTextControlFlowTest {

    private val forbidden = listOf(
        Regex(""""err\.[a-z_]+"""") to "diag err.* key literal",
        Regex("""msg_key|msgKey""") to "retired msg_key",
        Regex("""isPairingLost(Text|Error)""") to "text-matching pairing check",
    )

    private fun offences(name: String, text: String): List<String> =
        text.lines().withIndex().flatMap { (i, line) ->
            forbidden.filter { (re, _) -> re.containsMatchIn(line) }.map { (_, why) -> "$name:${i + 1}: $why: ${line.trim()}" }
        }

    @Test
    fun `the scanner catches the old shapes`() {
        val old = """
            if (rejected.msgKey?.let(::isPairingLostText) == true) return
            "storage_full" -> ok
            text.contains("err.not_authorized")
            val k = (error?.get("msg_key") as? JsonPrimitive)
        """.trimIndent()
        assertEquals(4, offences("sample", old).size)
        assertEquals(0, offences("sample", """if (isPairingLost(failure.kind)) return""").size)
    }

    @Test
    fun `no production source decides on text`() {
        val root = File("src/main/java")
        val files = root.walkTopDown().filter { it.isFile && it.extension == "kt" }.toList()
        assertTrue("scanned nothing", files.size > 50)
        // DiagText renders the desktop diag dictionary by key; it never sees a wire reply.
        val found = files.filter { !it.path.endsWith("i18n/DiagText.kt") }
            .flatMap { offences(it.relativeTo(root).path, it.readText()) }
        assertEquals(found.joinToString("\n"), 0, found.size)
    }
}
