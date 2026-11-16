package com.affluentlabs.zestssh

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Foreground service that keeps the Android process alive while SSH
 * connections are active. This prevents the OS from killing the Dart
 * isolate when the app is backgrounded, which is critical for:
 *   - Active port forwards (SSH tunnels)
 *   - Long-running terminal sessions
 *
 * The service itself does no networking work: the Dart isolate handles
 * all SSH traffic. This service simply holds a persistent notification
 * so Android treats the process as foreground-priority.
 */
class SshForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "zestssh_ssh_connections"
        const val NOTIFICATION_ID = 9001
        const val ACTION_UPDATE_COUNT = "com.affluentlabs.zestssh.UPDATE_COUNT"
        const val EXTRA_COUNT = "connection_count"
        // The open sessions' names, one line each when the notification is pulled
        // down (3.2): a host with several sessions comes once, "web-02 (2)".
        const val EXTRA_NAMES = "session_names"
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val count = intent?.getIntExtra(EXTRA_COUNT, 1) ?: 1
        val names = intent?.getStringArrayListExtra(EXTRA_NAMES) ?: arrayListOf()

        if (intent?.action == ACTION_UPDATE_COUNT) {
            // Just update the notification text
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.notify(NOTIFICATION_ID, buildNotification(count, names))
        } else {
            // Start as foreground service
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIFICATION_ID,
                    buildNotification(count, names),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                )
            } else {
                startForeground(NOTIFICATION_ID, buildNotification(count, names))
            }
        }

        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        // In the device's language (values-*/strings.xml); made again at each
        // start, so a channel made before takes the words too.
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.notification_channel_name),
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = getString(R.string.notification_channel_description)
            setShowBadge(false)
        }
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(count: Int, names: List<String>): Notification {
        // In the device's language (values-*/strings.xml); it was English.
        val label = if (count == 1) {
            getString(R.string.notification_active_one)
        } else {
            resources.getQuantityString(R.plurals.notification_active_sessions, count, count)
        }

        // Tap the notification to bring the app to the foreground
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // On the lock screen only the count: the hosts' names wait for the phone
        // to be unlocked.
        val public = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("ZestSSH")
            .setContentText(label)
            .setSmallIcon(R.mipmap.ic_launcher)
            .build()

        val builder = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("ZestSSH")
            .setContentText(label)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setContentIntent(pendingIntent)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setPublicVersion(public)
        // Pulled down, it lists the open sessions under the count.
        if (names.isNotEmpty()) {
            val style = Notification.InboxStyle().setBigContentTitle(label)
            names.forEach { style.addLine(it) }
            builder.setStyle(style)
        }
        return builder.build()
    }
}
