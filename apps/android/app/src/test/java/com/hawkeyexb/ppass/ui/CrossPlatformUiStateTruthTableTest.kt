package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.backup.MediaAccess
import com.hawkeyexb.ppass.backup.ScopeTime
import com.hawkeyexb.ppass.backup.initialScopeTime
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class CrossPlatformUiStateTruthTableTest {

    private fun repoRoot(): File {
        var dir = File(System.getProperty("user.dir") ?: ".")
        while (!File(dir, "assets/contracts/ui-state-truth-table.json").isFile) {
            dir = dir.parentFile ?: error("ui-state-truth-table.json not found above ${System.getProperty("user.dir")}")
        }
        return dir
    }

    private fun loadTruthTable(): JSONObject {
        val file = File(repoRoot(), "assets/contracts/ui-state-truth-table.json")
        return JSONObject(file.readText())
    }

    @Test
    fun connectionStatesMatchTruthTable() {
        val root = loadTruthTable()
        val array = root.getJSONArray("connection_states")
        for (i in 0 until array.length()) {
            val item = array.getJSONObject(i)
            val id = item.getString("id")
            val pairingLost = item.getBoolean("pairing_lost")
            val subState = SubscriptionSessionState(
                subscribeConnected = item.getBoolean("subscribe_connected"),
                subscribeExhausted = item.getBoolean("subscribe_exhausted"),
                subscribeHadFailure = item.getBoolean("subscribe_had_failure"),
            )
            val expectedStatus = ConnectionState.Status.valueOf(item.getString("expected_status"))
            val expectedConnected = item.getBoolean("is_connected")
            val expectedNeedsRepair = item.getBoolean("needs_repair")

            val actual = connectionStateOf(pairingLost = pairingLost, state = subState)
            assertEquals("[$id] status 匹配", expectedStatus, actual.status)
            assertEquals("[$id] isConnected 匹配", expectedConnected, actual.isConnected)
            assertEquals("[$id] needsRepair 匹配", expectedNeedsRepair, actual.needsRepair)

            val expectedDotColor = when (item.getString("detail_dot_color")) {
                "ACT" -> PPColor.Act
                "SAFE" -> PPColor.Safe
                "WAITING" -> PPColor.Waiting
                "IDLE" -> PPColor.Idle
                else -> error("Unknown dot color: ${item.getString("detail_dot_color")}")
            }
            assertEquals("[$id] storageDetailDotColor 匹配", expectedDotColor, storageDetailDotColor(actual.status))
        }
    }

    @Test
    fun photosGuidesMatchTruthTable() {
        val root = loadTruthTable()
        val array = root.getJSONArray("photos_guides")
        for (i in 0 until array.length()) {
            val item = array.getJSONObject(i)
            val id = item.getString("id")
            val facts = GuideFacts(
                scopeOn = item.getBoolean("scope_on"),
                firstUploaded = item.getBoolean("first_uploaded"),
                backgroundOn = item.getBoolean("background_on"),
                finished = item.getBoolean("finished"),
            )
            val firstChoicePending = item.getBoolean("first_choice_pending")
            val rawGuide = photosGuideOf(facts)
            val actual = com.hawkeyexb.ppass.guideForCurrentScope(rawGuide, firstChoicePending)
            val expected = PhotosGuide.valueOf(item.getString("expected_guide"))
            assertEquals("[$id] photos guide 匹配", expected, actual)
        }
    }

    @Test
    fun scopeAccessPoliciesMatchTruthTable() {
        val root = loadTruthTable()
        val array = root.getJSONArray("scope_access_policies")
        for (i in 0 until array.length()) {
            val item = array.getJSONObject(i)
            val access = MediaAccess.valueOf(item.getString("access"))
            val expectedOffers = item.getBoolean("offers_album_choices")
            assertEquals("[$access] offersAlbumChoices 匹配", expectedOffers, bucketScreenOffersAlbumChoices(access))
        }
    }

    @Test
    fun initialScopeTimesMatchTruthTable() {
        val root = loadTruthTable()
        val array = root.getJSONArray("initial_scope_times")
        for (i in 0 until array.length()) {
            val item = array.getJSONObject(i)
            val id = item.getString("id")
            val saved = item.getBoolean("saved")
            val hasSince = item.getBoolean("has_since")
            val partialAccess = item.getBoolean("partial_access")
            val sinceSec = if (hasSince) 1700000000L else null
            val actual = initialScopeTime(saved = saved, sinceSec = sinceSec, partialAccess = partialAccess)
            val expected = ScopeTime.valueOf(item.getString("expected_choice"))
            assertEquals("[$id] initialScopeTime 匹配", expected, actual)
        }
    }

    @Test
    fun heroIdleLineColorsMatchTruthTable() {
        val root = loadTruthTable()
        val array = root.getJSONArray("hero_idle_line_colors")
        for (i in 0 until array.length()) {
            val item = array.getJSONObject(i)
            val id = item.getString("id")
            val waitReason = if (item.getBoolean("has_wait_reason")) 1 else null
            val line = when (item.getString("line_type")) {
                "AllSafe" -> StatusLine.AllSafe
                "Pending" -> StatusLine.Pending(3)
                "Paused" -> StatusLine.Paused
                "Trouble" -> StatusLine.Trouble
                "Ready" -> StatusLine.Ready
                else -> error("Unknown line_type: ${item.getString("line_type")}")
            }
            val allSafeAllowed = item.getBoolean("all_safe_allowed")
            val actual = heroIdleLineColor(waitReason = waitReason, line = line, allSafeAllowed = allSafeAllowed)
            val expected = when (item.getString("expected_color")) {
                "WAITING" -> PPColor.Waiting
                "SAFE" -> PPColor.Safe
                "SECONDARY" -> PPColor.Ink60
                else -> error("Unknown color: ${item.getString("expected_color")}")
            }
            assertEquals("[$id] heroIdleLineColor 匹配", expected, actual)
        }
    }

    @Test
    fun heroFromTodayEmptyMatchesTruthTable() {
        val root = loadTruthTable()
        val array = root.getJSONArray("hero_from_today_empties")
        for (i in 0 until array.length()) {
            val item = array.getJSONObject(i)
            val id = item.getString("id")
            val render = item.getString("render")
            val countM = item.getLong("count_m")
            val countN = item.getLong("count_n")
            val hasSinceToday = item.getBoolean("has_since_today")
            val expected = item.getBoolean("expected_empty")

            val actual = render == "Triplet" && countM == 0L && countN == 0L && hasSinceToday
            assertEquals("[$id] heroFromTodayEmpty 匹配", expected, actual)
        }
    }
}
