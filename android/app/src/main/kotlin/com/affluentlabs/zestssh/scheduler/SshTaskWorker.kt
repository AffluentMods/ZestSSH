package com.affluentlabs.zestssh.scheduler

import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.work.CoroutineWorker
import com.affluentlabs.zestssh.R
import androidx.work.WorkerParameters

/**
 * WorkManager [CoroutineWorker] that triggers SSH automation tasks.
 *
 * When the scheduler fires, the worker reads task parameters from [inputData]
 * and launches the MainActivity with an automation intent. The Flutter engine
 * picks up the intent and delegates to [AutomationService] for headless SSH
 * execution.
 *
 * This approach reuses the existing automation infrastructure (API key
 * validation, headless execution, history logging) without duplicating any
 * SSH logic on the native side.
 */
class SshTaskWorker(
    context: Context,
    params: WorkerParameters
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val action = inputData.getString("action") ?: return Result.failure()
        // A workflow names its hosts in its own steps, so a workflow task
        // has no connection: the app saves it with an empty one, which this
        // refused, and no scheduled workflow ever ran (found 22 October 2026
        // while the 3.0 docs were checked).
        val connectionId = inputData.getString("connection_id") ?: ""
        val apiKeyId = inputData.getString("api_key_id") ?: return Result.failure()

        // Optional fields
        val command = inputData.getString("command")
        val snippetName = inputData.getString("snippet_name")
        val workflowId = inputData.getString("workflow_id")
        val workflowName = inputData.getString("workflow_name")
        // The app's own id of the task, so that the app can write the run
        // to it (its Last); tasks scheduled before it was passed have none.
        val taskId = inputData.getString("task_id")

        // ── Input validation ────────────────────────────────────────
        // Reject unrecognized actions to prevent misuse.
        val validActions = setOf("execute", "snippet", "workflow", "connect")
        if (action !in validActions) return Result.failure()

        if (action == "workflow") {
            // A workflow is named by its id or its name.
            if (workflowId.isNullOrBlank() && workflowName.isNullOrBlank()) return Result.failure()
        } else {
            // Connection ID must be non-blank and reasonably sized.
            if (connectionId.isBlank()) return Result.failure()
        }
        if (connectionId.length > 256) return Result.failure()

        // Command length must be bounded to prevent abuse.
        if (command != null && command.length > 4096) return Result.failure()

        // Map the action string to the correct automation intent
        val intentAction = when (action) {
            "execute" -> ACTION_EXECUTE
            "snippet" -> ACTION_SNIPPET
            "workflow" -> ACTION_WORKFLOW
            "connect" -> ACTION_CONNECT
            else -> return Result.failure()
        }

        // Pass only the API key ID. No secret is stored for the task, and none
        // is looked up or substituted: the app keeps only each key's hash, and
        // the Flutter automation handler checks a scheduled run by the key's id
        // (there, not expired, marked used). The raw key is never in
        // WorkManager's on-disk job data.
        //
        // SECURITY: because the id alone lets a run through and MainActivity is
        // exported, accompany it with a one-time launch token written to
        // app-private storage. MainActivity only honours `api_key_id` when the
        // token verifies, proving THIS (in-app) scheduler sent the intent: a
        // third-party app with a leaked id can neither read the token nor forge
        // it. See [ScheduledLaunchTokens].
        // Android 10 and later do not let an app start an activity from the
        // background (a WorkManager job is the background): the start was
        // dropped, and the task never ran unless the app was open (22 October
        // 2026, while the 3.0 docs were checked). Open, it starts at once; otherwise the
        // person is asked, with a notification whose tap starts it, the way
        // Android allows. The tap may come later, so its token lives as long
        // as the notification does.
        val appOpen = appIsVisible()
        val launchToken = ScheduledLaunchTokens.issue(
            applicationContext,
            if (appOpen) ScheduledLaunchTokens.TTL_MS else TAP_TO_RUN_TTL_MS,
        )
        val intent = Intent(applicationContext, Class.forName("com.affluentlabs.zestssh.MainActivity")).apply {
            this.action = intentAction
            putExtra("connection_id", connectionId)
            putExtra("api_key_id", apiKeyId)
            putExtra("scheduled_launch_token", launchToken)
            if (command != null) putExtra("command", command)
            if (snippetName != null) putExtra("snippet_name", snippetName)
            if (workflowId != null) putExtra("workflow_id", workflowId)
            if (workflowName != null) putExtra("workflow_name", workflowName)
            if (taskId != null) putExtra("scheduled_task_id", taskId)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }

        if (appOpen) {
            applicationContext.startActivity(intent)
            return Result.success()
        }
        return if (askToRun(intent, taskId)) Result.success() else Result.failure()
    }

    /** Whether one of the app's windows can be seen, so it may start one. */
    private fun appIsVisible(): Boolean {
        val state = ActivityManager.RunningAppProcessInfo()
        ActivityManager.getMyMemoryState(state)
        return state.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE
    }

    /**
     * A notification whose tap runs the task: an activity started from a
     * notification the person taps is one Android allows. False where the
     * app may post none (notifications turned off for it).
     */
    private fun askToRun(intent: Intent, taskId: String?): Boolean {
        val context = applicationContext
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (!manager.areNotificationsEnabled()) return false
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                context.getString(R.string.scheduled_channel_name),
                NotificationManager.IMPORTANCE_HIGH,
            ).apply { description = context.getString(R.string.scheduled_channel_description) }
        )
        // One notification for each task (a task fired again replaces its own).
        val id = NOTIFICATION_BASE + ((taskId ?: inputData.toString()).hashCode() and 0xFFFF)
        val tap = PendingIntent.getActivity(
            context,
            id,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = Notification.Builder(context, CHANNEL_ID)
            .setContentTitle(context.getString(R.string.scheduled_ready_title))
            .setContentText(context.getString(R.string.scheduled_ready_text))
            .setStyle(Notification.BigTextStyle().bigText(context.getString(R.string.scheduled_ready_text)))
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(tap)
            .setAutoCancel(true)
            // Gone when its token is: a tap after that could not run it.
            .setTimeoutAfter(TAP_TO_RUN_TTL_MS)
            .build()
        manager.notify(id, notification)
        return true
    }

    companion object {
        private const val CHANNEL_ID = "zestssh_scheduled_tasks"
        private const val NOTIFICATION_BASE = 0x5A000

        /** How long a scheduled task waits for its tap: twelve hours. */
        private const val TAP_TO_RUN_TTL_MS = 12 * 60 * 60 * 1000L

        private const val ACTION_CONNECT = "com.affluentlabs.zestssh.CONNECT"
        private const val ACTION_EXECUTE = "com.affluentlabs.zestssh.EXECUTE"
        private const val ACTION_SNIPPET = "com.affluentlabs.zestssh.SNIPPET"
        private const val ACTION_WORKFLOW = "com.affluentlabs.zestssh.WORKFLOW"
    }
}
