package de.kerlhandel.vmflow

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import androidx.core.content.getSystemService
import dagger.hilt.android.HiltAndroidApp
import de.kerlhandel.vmflow.data.remote.SupabaseClientProvider
import javax.inject.Inject

@HiltAndroidApp
class VMflowApp : Application() {
    @Inject lateinit var supabaseClientProvider: SupabaseClientProvider

    override fun onCreate() {
        super.onCreate()
        supabaseClientProvider.initialize()
        createNotificationChannels()
    }

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService<NotificationManager>() ?: return

        val channels = listOf(
            NotificationChannel(
                CHANNEL_SALES, getString(R.string.settings_notif_sale),
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = getString(R.string.settings_notif_sale_desc)
                setShowBadge(false)
            },
            NotificationChannel(
                CHANNEL_LOW_STOCK, getString(R.string.settings_notif_low_stock),
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = getString(R.string.settings_notif_low_stock_desc)
            },
            NotificationChannel(
                CHANNEL_INBOX, getString(R.string.settings_notif_inbox),
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = getString(R.string.settings_notif_inbox_desc)
                setShowBadge(true)
            },
            NotificationChannel(
                CHANNEL_GENERAL, "General",
                NotificationManager.IMPORTANCE_DEFAULT,
            ),
        )
        manager.createNotificationChannels(channels)
    }

    companion object {
        const val CHANNEL_SALES = "sales"
        const val CHANNEL_LOW_STOCK = "low_stock"
        const val CHANNEL_INBOX = "inbox"
        const val CHANNEL_GENERAL = "general"
    }
}
