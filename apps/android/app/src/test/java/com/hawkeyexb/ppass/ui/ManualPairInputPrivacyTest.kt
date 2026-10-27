// #1149：手输配对串的输入框不进输入法词库——向输入法声明不联想、不做个性化学习。
// 反证：`markNoSuggestionsNoLearning` 不设标记，或输入框没包 `NoPersonalizedLearning`
// ⇒ 对应一条变红。
package com.hawkeyexb.ppass.ui

import android.text.InputType
import android.view.inputmethod.EditorInfo
import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

class ManualPairInputPrivacyTest {
    @Test
    fun `the editor info asks for no suggestions and no personalized learning`() {
        val info = EditorInfo()
        info.inputType = InputType.TYPE_CLASS_TEXT
        info.imeOptions = EditorInfo.IME_ACTION_DONE
        markNoSuggestionsNoLearning(info)
        assertTrue(info.inputType and InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS != 0)
        assertTrue(info.imeOptions and EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING != 0)
        assertTrue("existing flags survive", info.inputType and InputType.TYPE_CLASS_TEXT != 0)
        assertTrue("existing flags survive", info.imeOptions and EditorInfo.IME_ACTION_DONE != 0)
    }

    @Test
    fun `the manual pairing field is wrapped by the no-learning interceptor`() {
        val src = listOf("src/main/java", "app/src/main/java")
            .map { File(it, "com/hawkeyexb/ppass/ui/ScanScreen.kt") }
            .first { it.isFile }
            .readText()
        val wrapped = src.substringAfter("NoPersonalizedLearning {").substringBefore("OutlinedButton(")
        assertTrue(
            "the BasicTextField for the pairing string must sit inside NoPersonalizedLearning",
            wrapped.contains("BasicTextField(") && wrapped.contains("autoCorrectEnabled = false"),
        )
    }
}
