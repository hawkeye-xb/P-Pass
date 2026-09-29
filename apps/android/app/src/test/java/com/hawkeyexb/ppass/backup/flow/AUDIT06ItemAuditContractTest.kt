// AUDIT-06 (#460): 手机真实发出的逐张审计（flow.item.*）形状 == 两端共享的契约锚点
// `tests/flow-audit-item-events.json` 里 phone-current 的形状；桌面那边（crates/daemon audit_route 测试）读同一份文件，
// 证明每一种形状都被收下、落库。以前两端各测各的：桌面测带 itemRef 的形状，手机从来不发 itemRef，于是一条都不收。
// 反证：FlowEngine 的 itemAudit 不加 itemRef（退回 audit(kind, payload)）→ 每个场景的 itemRef 断言都红。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.order.AuditRecord
import com.hawkeyexb.ppass.backup.order.OrderState
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class AUDIT06ItemAuditContractTest {

    private val itemKinds = setOf(AuditKinds.ITEM_CONFIRMED, AuditKinds.ITEM_SOURCE_MISSING, AuditKinds.ITEM_ATTENTION)

    /** 契约锚点里 phone-current 的 (kind, payload 键集合)。 */
    private val currentShapes: Set<Pair<String, Set<String>>> by lazy {
        // 单测的 CWD = apps/android/app；往上找仓库根。
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "tests/flow-audit-item-events.json").isFile) {
            dir = dir.parentFile ?: error("tests/flow-audit-item-events.json not found above ${System.getProperty("user.dir")}")
        }
        val doc = Json.parseToJsonElement(File(dir, "tests/flow-audit-item-events.json").readText()).jsonObject
        doc.getValue("events").jsonArray.map { it.jsonObject }
            .filter { it.getValue("emitter").jsonPrimitive.content == "phone-current" }
            .map { it.getValue("kind").jsonPrimitive.content to it.getValue("payload").jsonObject.keys }
            .toSet()
    }

    private fun itemAudits(rig: Rig): List<AuditRecord> = rig.store.pendingAudit(1_000).filter { it.kind in itemKinds }

    private fun scenario(test: TestScope, setup: Rig.() -> Long): Pair<Long, List<AuditRecord>> {
        val rig = Rig(test)
        val mediaId = rig.setup()
        rig.trigger()
        val audits = itemAudits(rig)
        rig.close()
        return mediaId to audits
    }

    @Test
    fun every_item_fact_the_phone_emits_carries_itemRef_and_matches_the_shared_contract() = runTest {
        val scenarios = listOf(
            "confirmed" to scenario(this) { photo(1, generation = 1); 1L },
            "source missing on import" to scenario(this) { photo(2, generation = 1); importer.unreadable += 2L; 2L },
            "source missing during delivery" to scenario(this) {
                photo(3, generation = 1)
                delivery.script += { DeliveryOutcome.SourceMissing }
                3L
            },
            "item failure" to scenario(this) {
                photo(4, generation = 1)
                repeat(2) { delivery.script += { DeliveryOutcome.ItemFailure("boom") } }
                4L
            },
            "legacy order whose version changed" to scenario(this) {
                val v1 = photo(5, generation = 1, content = "old")
                order(v1, OrderState.TRANSFERRING)
                media.put(v1.copy(modified = 999, content = "new", generation = 2))
                5L
            },
        )
        val observed = mutableSetOf<Pair<String, Set<String>>>()
        for ((name, result) in scenarios) {
            val (mediaId, audits) = result
            assertTrue("$name: produced no item audit", audits.isNotEmpty())
            for (a in audits) {
                assertEquals("$name: ${a.kind} must carry the item identity", "media:$mediaId", a.payload["itemRef"])
                val shape = a.kind to a.payload.keys
                assertTrue("$name: $shape is not a phone-current shape in tests/flow-audit-item-events.json", shape in currentShapes)
                observed += shape
            }
        }
        assertEquals("every phone-current shape in the fixture is really emitted (no stale fixture rows)", currentShapes, observed)
    }
}
