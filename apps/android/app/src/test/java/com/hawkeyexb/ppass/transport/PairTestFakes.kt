// #1118: fakes for the pairing state machine — the PAKE core and the user-facing ceremony,
// so the JVM tests drive the real [awaitPairVerdict] without the native library.
package com.hawkeyexb.ppass.transport

/** A [PairPhoneCore] that records its calls and mimics the real call order (finish once, verify after finish). */
class FakePairPhone(
    val pakeA: String = "aa".repeat(33),
    val confirmA: String = "c1".repeat(32),
    private val verifyOk: Boolean = true,
    private val finishFails: Boolean = false,
) : PairPhoneCore {
    val calls = mutableListOf<String>()
    private var finished = false

    override fun pakeA(): String = pakeA

    override fun finish(pakeB: String): String {
        calls += "finish:$pakeB"
        check(!finished) { "finish called twice" }
        if (finishFails) error("malformed pake_b")
        finished = true
        return confirmA
    }

    override fun verify(confirmB: String) {
        calls += "verify:$confirmB"
        check(finished) { "verify before finish" }
        check(verifyOk) { "confirm_b does not verify" }
    }
}

/** A [PairCeremony] fake. [events] records the order of everything user-visible. */
class FakeCeremony(
    val phone: FakePairPhone = FakePairPhone(),
    val code: String = "123456",
    /** Shared with the fake desktop so the order of RPCs and user-visible steps is one list. */
    val events: MutableList<String> = mutableListOf(),
) : PairCeremony {
    var desktopNameSeen: String? = "unset"

    override fun newCode(): String = code.also { events += "newCode" }

    override fun start(code: String): PairPhoneCore {
        events += "start:$code"
        return phone
    }

    override fun showCode(code: String, desktopName: String?) {
        events += "showCode:$code"
        desktopNameSeen = desktopName
    }
}
