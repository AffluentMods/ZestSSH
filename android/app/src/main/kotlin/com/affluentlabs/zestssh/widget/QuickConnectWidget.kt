package com.affluentlabs.zestssh.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.RemoteViews
import com.affluentlabs.zestssh.R
import org.json.JSONArray

/**
 * Home screen widget showing recent SSH connections for quick access.
 *
 * Data is provided by the Flutter app via SharedPreferences under the key
 * "flutter.widget_connections" as a JSON array of objects:
 *   [{"id":"uuid","label":"My Server","host":"10.0.0.1","port":22}, ...]
 * and "flutter.widget_locked": the app lock is on (lib/services/widget_service.dart).
 * Then the list is empty and the widget lists no host, only that the app is
 * locked (4.0, as the iPhone's widget).
 */
class QuickConnectWidget : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        for (appWidgetId in appWidgetIds) {
            updateWidget(context, appWidgetManager, appWidgetId)
        }
    }

    companion object {
        private const val MAX_CONNECTIONS = 4

        fun updateWidget(
            context: Context,
            appWidgetManager: AppWidgetManager,
            appWidgetId: Int
        ) {
            val views = RemoteViews(context.packageName, R.layout.widget_quick_connect)
            val locked = isLocked(context)
            // Locked, no host is shown, even one an older version left.
            val connections = if (locked) emptyList() else loadConnections(context)

            // Header tap → open app
            val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            if (launchIntent != null) {
                val pendingLaunch = PendingIntent.getActivity(
                    context, 0, launchIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                views.setOnClickPendingIntent(R.id.widget_header, pendingLaunch)
            }

            // "+" button → new connection deep link
            val addIntent = Intent(Intent.ACTION_VIEW, Uri.parse("zestssh://connection/new"))
            addIntent.setPackage(context.packageName)
            val pendingAdd = PendingIntent.getActivity(
                context, 1, addIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.widget_add_btn, pendingAdd)

            // Connection slots
            val slotIds = intArrayOf(
                R.id.widget_conn_1, R.id.widget_conn_2,
                R.id.widget_conn_3, R.id.widget_conn_4
            )
            val labelIds = intArrayOf(
                R.id.widget_label_1, R.id.widget_label_2,
                R.id.widget_label_3, R.id.widget_label_4
            )
            val hostIds = intArrayOf(
                R.id.widget_host_1, R.id.widget_host_2,
                R.id.widget_host_3, R.id.widget_host_4
            )

            for (i in slotIds.indices) {
                if (i < connections.size) {
                    val conn = connections[i]
                    views.setTextViewText(labelIds[i], conn.label)
                    views.setTextViewText(hostIds[i], conn.host)
                    views.setViewVisibility(slotIds[i], android.view.View.VISIBLE)

                    // Tap → connect via deep link (use connection ID for direct lookup)
                    val connectIntent = Intent(
                        Intent.ACTION_VIEW,
                        Uri.parse("zestssh://connect?id=${Uri.encode(conn.id)}")
                    )
                    connectIntent.setPackage(context.packageName)
                    val pendingConnect = PendingIntent.getActivity(
                        context, 10 + i, connectIntent,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                    )
                    views.setOnClickPendingIntent(slotIds[i], pendingConnect)
                } else {
                    views.setViewVisibility(slotIds[i], android.view.View.GONE)
                }
            }

            // Show empty state if no connections, or that the app is locked
            if (connections.isEmpty()) {
                views.setTextViewText(
                    R.id.widget_empty,
                    context.getString(if (locked) R.string.widget_locked else R.string.widget_empty)
                )
                views.setViewVisibility(R.id.widget_empty, android.view.View.VISIBLE)
            } else {
                views.setViewVisibility(R.id.widget_empty, android.view.View.GONE)
            }

            appWidgetManager.updateAppWidget(appWidgetId, views)
        }

        private fun isLocked(context: Context): Boolean {
            val prefs = context.getSharedPreferences(
                "FlutterSharedPreferences", Context.MODE_PRIVATE
            )
            return prefs.getBoolean("flutter.widget_locked", false)
        }

        private fun loadConnections(context: Context): List<ConnectionInfo> {
            val prefs = context.getSharedPreferences(
                "FlutterSharedPreferences", Context.MODE_PRIVATE
            )
            val json = prefs.getString("flutter.widget_connections", null) ?: return emptyList()

            return try {
                val array = JSONArray(json)
                val list = mutableListOf<ConnectionInfo>()
                for (i in 0 until minOf(array.length(), MAX_CONNECTIONS)) {
                    val obj = array.getJSONObject(i)
                    list.add(
                        ConnectionInfo(
                            id = obj.optString("id", ""),
                            label = obj.optString("label", "Server"),
                            host = obj.optString("host", ""),
                            port = obj.optInt("port", 22)
                        )
                    )
                }
                list
            } catch (e: Exception) {
                emptyList()
            }
        }
    }

    private data class ConnectionInfo(
        val id: String,
        val label: String,
        val host: String,
        val port: Int
    )
}
