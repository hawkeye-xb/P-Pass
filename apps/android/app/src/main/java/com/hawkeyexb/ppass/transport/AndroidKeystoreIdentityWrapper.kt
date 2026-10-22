// #1106: the Android Keystore half of IdentityStore — a non-exportable AES-256-GCM key that seals
// the 32-byte device secret.
//
// Deliberately NOT set: setUserAuthenticationRequired (a lock-screen change would invalidate the
// key and with it the device), setUnlockedDeviceRequired (background backup runs while the phone
// is locked), setIsStrongBoxBacked (the key is used once per process; TEE is enough and StrongBox
// is slow and unevenly implemented). No component is directBootAware, so the process never runs
// before the first unlock.
package com.hawkeyexb.ppass.transport

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
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
