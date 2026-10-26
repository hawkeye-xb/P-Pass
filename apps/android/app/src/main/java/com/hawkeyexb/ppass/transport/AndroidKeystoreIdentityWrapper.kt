// #1106: the Android Keystore half of IdentityStore — a non-exportable AES-256-GCM key that seals
// the 32-byte device secret.
//
// Deliberately NOT set: setUserAuthenticationRequired (a lock-screen change would invalidate the
// key and with it the device), setUnlockedDeviceRequired (background backup runs while the phone
// is locked), setIsStrongBoxBacked (the key is used once per process; TEE is enough and StrongBox
// is slow and unevenly implemented). No component is directBootAware, so the process never runs
// before the first unlock.
package com.hawkeyexb.ppass.transport

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec

class AndroidKeystoreIdentityWrapper(private val alias: String = ALIAS) : IdentityKeyWrapper {

    private fun keyStore(): KeyStore = KeyStore.getInstance(PROVIDER).apply { load(null) }

    override fun exists(): Boolean = keyStore().containsAlias(alias)

    override fun recreate() {
        keyStore().let { if (it.containsAlias(alias)) it.deleteEntry(alias) }
        KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER).apply {
            init(
                KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build(),
            )
        }.generateKey()
    }

    override fun seal(plain: ByteArray): SealedSecret {
        // Randomized encryption (the default): Keystore picks the IV; passing one would throw.
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        cipher.updateAAD(AAD)
        val ciphertext = cipher.doFinal(plain)
        return SealedSecret(cipher.iv, ciphertext)
    }

    override fun open(sealed: SealedSecret): ByteArray {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        try {
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(TAG_BITS, sealed.iv))
        } catch (e: KeyPermanentlyInvalidatedException) {
            throw IdentityKeyGoneException("wrapping key permanently invalidated", e)
        }
        cipher.updateAAD(AAD)
        return cipher.doFinal(sealed.ciphertext)
    }

    /** #1152：包裹密钥所在的安全级别（诊断日志用）。读不出来就如实说读不出来，不抛。 */
    override fun securityLevel(): String = try {
        val key = key()
        val info = SecretKeyFactory.getInstance(key.algorithm, PROVIDER).getKeySpec(key, KeyInfo::class.java) as KeyInfo
        describeKeySecurityLevel(
            Build.VERSION.SDK_INT,
            if (Build.VERSION.SDK_INT >= 31) info.securityLevel else null,
            @Suppress("DEPRECATION") info.isInsideSecureHardware,
        )
    } catch (e: Exception) {
        "unreadable(${e.javaClass.simpleName})"
    }

    private fun key(): SecretKey =
        keyStore().getKey(alias, null) as? SecretKey ?: throw IdentityKeyGoneException("wrapping key absent")

    private companion object {
        const val PROVIDER = "AndroidKeyStore"
        const val ALIAS = "ppass.identity.wrap.v1"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val TAG_BITS = 128
        val AAD = "ppass.identity.v1".toByteArray()
    }
}

/**
 * KeyInfo → 人能读的级别（纯函数，JVM 单测直接测）。API 31+ 用 `KeyInfo.getSecurityLevel()`
 * （`KeyProperties.SECURITY_LEVEL_*`），更低的版本只有 `isInsideSecureHardware` 一个布尔。
 */
internal fun describeKeySecurityLevel(sdkInt: Int, securityLevel: Int?, insideSecureHardware: Boolean): String =
    if (sdkInt >= 31 && securityLevel != null) {
        when (securityLevel) {
            2 -> "strongbox" // SECURITY_LEVEL_STRONGBOX
            1 -> "tee" // SECURITY_LEVEL_TRUSTED_ENVIRONMENT
            0 -> "software" // SECURITY_LEVEL_SOFTWARE
            -1 -> "unknown_secure" // SECURITY_LEVEL_UNKNOWN_SECURE
            else -> "unknown" // SECURITY_LEVEL_UNKNOWN
        }
    } else if (insideSecureHardware) {
        "secure_hardware"
    } else {
        "software"
    }
