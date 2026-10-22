// #1106: JVM stand-in for Android Keystore — real AES-256-GCM (so tampering really fails the tag)
// with a key that lives in this object, plus per-operation fault injection.
package com.hawkeyexb.ppass.transport

import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class FakeIdentityKeyWrapper : IdentityKeyWrapper {
    var key: SecretKey? = null
    var recreated = 0

    /** Set to make calls of that operation throw what it returns (hook or result null = behave). */
    var failExists: (() -> Exception?)? = null
    var failRecreate: (() -> Exception?)? = null
    var failSeal: (() -> Exception?)? = null
    var failOpen: (() -> Exception?)? = null

    /** Hands back different bytes than were sealed (a broken Keystore that "succeeds"). */
    var corruptOpen = false

    override fun exists(): Boolean {
        failExists?.invoke()?.let { throw it }
        return key != null
    }

    override fun recreate() {
        failRecreate?.invoke()?.let { throw it }
        key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        recreated++
    }

    override fun seal(plain: ByteArray): SealedSecret {
        failSeal?.invoke()?.let { throw it }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key ?: throw IdentityKeyGoneException("absent"))
        return SealedSecret(cipher.iv, cipher.doFinal(plain))
    }

    override fun open(sealed: SealedSecret): ByteArray {
        failOpen?.invoke()?.let { throw it }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key ?: throw IdentityKeyGoneException("absent"), GCMParameterSpec(128, sealed.iv))
        val plain = cipher.doFinal(sealed.ciphertext)
        if (corruptOpen) plain[0] = (plain[0].toInt() xor 1).toByte()
        return plain
    }
}
