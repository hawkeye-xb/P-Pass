// ARCH-09: source existence is a one-open probe, never a content read or hash.
package com.hawkeyexb.ppass.backup.flow

import android.content.ContentResolver
import android.net.Uri

class ContentResolverSourcePresenceProbe(private val resolver: ContentResolver) {
    fun presence(sourceRef: String): SourcePresence =
        runCatching {
            resolver.openInputStream(Uri.parse(sourceRef))?.use { }
                ?: return SourcePresence.MISSING
            SourcePresence.PRESENT
        }.getOrDefault(SourcePresence.MISSING)
}
