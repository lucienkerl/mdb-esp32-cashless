package de.kerlhandel.vmflow.push

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import dagger.hilt.android.AndroidEntryPoint
import de.kerlhandel.vmflow.MainActivity
import de.kerlhandel.vmflow.R
import de.kerlhandel.vmflow.VMflowApp
import de.kerlhandel.vmflow.data.repository.NotificationRepository
import de.kerlhandel.vmflow.di.ApplicationScope
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Receives FCM messages — posts a notification in the appropriate channel
 * based on the `type` data field.
 *
 * Deep-link: tapping a notification opens MainActivity with an `inbox` extra
 * when `type == "inbox"` so [RootScreen] can route there.
 */
@AndroidEntryPoint
class VMflowMessagingService : FirebaseMessagingService() {

    @Inject lateinit var notificationRepository: NotificationRepository
    @Inject @ApplicationScope lateinit var appScope: CoroutineScope

    override fun onNewToken(token: String) {
        appScope.launch { notificationRepository.registerToken(token) }
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data
        val type = data["type"] ?: "general"
        val channelId = when (type) {
            "sale" -> VMflowApp.CHANNEL_SALES
            "low_stock" -> VMflowApp.CHANNEL_LOW_STOCK
            "inbox" -> VMflowApp.CHANNEL_INBOX
            else -> VMflowApp.CHANNEL_GENERAL
        }
        val title = message.notification?.title ?: data["title"] ?: "VMflow"
        val body = message.notification?.body ?: data["body"].orEmpty()

        val builder = NotificationCompat.Builder(this, channelId)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setContentIntent(deepLinkIntent(this, type))

        // TODO: if data["image"] present, use a WorkManager-backed BigPicture style.

        NotificationManagerCompat.from(this).notify(
            (System.currentTimeMillis() % Int.MAX_VALUE).toInt(),
            builder.build(),
        )

        appScope.launch { notificationRepository.refreshBadge() }
    }

    private fun deepLinkIntent(context: Context, type: String): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            putExtra("deep_link", type)
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getActivity(context, type.hashCode(), intent, flags)
    }
}
