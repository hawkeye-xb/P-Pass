// LEGACY — frozen by REBUILD-00. These two types used to live in BackupRunner.kt
// (the ppf/upload/1 batch pipeline, removed in #988). ConfirmedStore still uses
// them; they go away with the rest of the legacy batch cluster.
package com.hawkeyexb.ppass.backup

import java.io.InputStream

/** One backup candidate: content + identity, source-agnostic
 *  (MediaStore URIs on the phone, plain files in tests). */
data class Candidate(
    val hash: String,
    val fileName: String,
    val mediaType: String,
    val bytes: Long,
    /** Re-openable content source. */
    val open: () -> InputStream,
)

data class BackupReport(
    val offered: Int,
    val pushed: Int,
    val ingested: Int,
    val duplicates: Int,
    /** DOG-01b: manifest 回 missing 的 hash 集合（校准确认缓存用——
     *  只查不传语义的产物，非新协议动词）。 */
    val missing: Set<String>,
)
