package com.hawkeyexb.ppass.battery

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings

/** Public system facts used to choose a future, tested vendor guidance profile. */
data class AndroidDeviceProfile(
    val manufacturer: String,
    val model: String,
    val sdkInt: Int,
)

/**
 * Boundary between background-backup policy and Android's permission surface.
 * Vendor-specific guidance may be added behind this port only after device proof;
 * every device currently uses the public Android battery-optimization request.
 */
interface BackgroundAuthorizationAdapter {
    fun deviceProfile(): AndroidDeviceProfile
    fun isGranted(): Boolean
    fun requestIntent(): Intent
}

class AndroidBackgroundAuthorizationAdapter(private val context: Context) : BackgroundAuthorizationAdapter {
    override fun deviceProfile(): AndroidDeviceProfile = AndroidDeviceProfile(
        manufacturer = Build.MANUFACTURER,
        model = Build.MODEL,
        sdkInt = Build.VERSION.SDK_INT,
    )

    override fun isGranted(): Boolean = isIgnoringBatteryOptimizations(context)

    override fun requestIntent(): Intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
        .setData(Uri.parse("package:${context.packageName}"))
}
