package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.R

internal object SettingsLayout {
    enum class Group { BACKUP, SELECTION, CONDITIONS }
    enum class Backup { RULE, SCOPE, BACKGROUND }
    enum class Condition { WIFI, NOTIFICATIONS, MORE }

    enum class Selection(val labelRes: Int) {
        PHOTOS(R.string.pick_from_photos_label),
        FILES(R.string.pick_from_files_label);

        fun isHeading(photoPickerAvailable: Boolean): Boolean =
            if (photoPickerAvailable) this == PHOTOS else this == FILES

        fun request(photos: () -> Unit, files: () -> Unit) {
            when (this) {
                PHOTOS -> photos()
                FILES -> files()
            }
        }
    }

    val sections: List<Group> = listOf(Group.BACKUP, Group.SELECTION, Group.CONDITIONS)
    val conditionRows: List<Condition> = listOf(Condition.WIFI, Condition.NOTIFICATIONS, Condition.MORE)

    fun backupRows(autoRule: Boolean): List<Backup> =
        if (autoRule) listOf(Backup.RULE, Backup.SCOPE, Backup.BACKGROUND) else listOf(Backup.RULE)

    fun selectionRows(photoPickerAvailable: Boolean): List<Selection> =
        if (photoPickerAvailable) listOf(Selection.PHOTOS, Selection.FILES) else listOf(Selection.FILES)
}
