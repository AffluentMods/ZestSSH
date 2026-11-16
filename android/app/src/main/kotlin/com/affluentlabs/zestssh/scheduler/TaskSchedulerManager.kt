package com.affluentlabs.zestssh.scheduler

import android.content.Context
import android.util.Log
import androidx.work.Data
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkInfo
import androidx.work.WorkManager
import kotlinx.coroutines.flow.first
import java.util.concurrent.TimeUnit

/**
 * Manages creation, cancellation, and querying of WorkManager tasks
 * for scheduled SSH automation.
 *
 * All periodic tasks use [ExistingPeriodicWorkPolicy.UPDATE] so re-scheduling
 * with the same ID updates the existing task rather than creating a duplicate.
 * One-shot tasks use [ExistingWorkPolicy.REPLACE] for the same reason.
 */
class TaskSchedulerManager(private val context: Context) {

    private val workManager = WorkManager.getInstance(context)

    /**
     * Schedule a recurring periodic task.
     *
     * @param taskId        Unique identifier (used as WorkManager unique work name).
     * @param action        Automation action: "execute", "snippet", "workflow", "connect".
     * @param connectionId  Target connection ID or label.
     * @param command       Shell command (for execute action).
     * @param apiKeyId      Automation API key ID (not the raw secret). The worker passes
     *                      this via the intent; Flutter looks up the actual key at runtime.
     * @param intervalMinutes  Repeat interval in minutes (minimum 15 per WorkManager).
     * @param initialDelayMinutes  Optional initial delay before first run.
     * @param snippetName   Snippet name (for snippet action).
     * @param workflowId    Workflow ID (for workflow action).
     * @param workflowName  Workflow name (for workflow action).
     */
    fun scheduleTask(
        taskId: String,
        action: String,
        connectionId: String,
        command: String?,
        apiKeyId: String,
        intervalMinutes: Long,
        initialDelayMinutes: Long = 0,
        snippetName: String? = null,
        workflowId: String? = null,
        workflowName: String? = null,
    ) {
        val inputData = buildInputData(
            taskId = taskId,
            action = action,
            connectionId = connectionId,
            command = command,
            apiKeyId = apiKeyId,
            snippetName = snippetName,
            workflowId = workflowId,
            workflowName = workflowName,
        )

        val request = PeriodicWorkRequestBuilder<SshTaskWorker>(
            intervalMinutes, TimeUnit.MINUTES
        ).apply {
            setInputData(inputData)
            addTag(TAG_SCHEDULED_TASK)
            addTag(taskId)
            if (initialDelayMinutes > 0) {
                setInitialDelay(initialDelayMinutes, TimeUnit.MINUTES)
            }
        }.build()

        workManager.enqueueUniquePeriodicWork(
            taskId,
            ExistingPeriodicWorkPolicy.UPDATE,
            request,
        )

        Log.i(TAG, "Scheduled periodic task '$taskId': every ${intervalMinutes}m, action=$action")
    }

    /**
     * Schedule a one-time delayed task.
     *
     * @param taskId        Unique identifier.
     * @param action        Automation action.
     * @param connectionId  Target connection.
     * @param command       Shell command (for execute action).
     * @param apiKeyId      Automation API key ID (not the raw secret).
     * @param delayMinutes  Delay before execution.
     * @param snippetName   Snippet name (for snippet action).
     * @param workflowId    Workflow ID (for workflow action).
     * @param workflowName  Workflow name (for workflow action).
     */
    fun scheduleOneShot(
        taskId: String,
        action: String,
        connectionId: String,
        command: String?,
        apiKeyId: String,
        delayMinutes: Long,
        snippetName: String? = null,
        workflowId: String? = null,
        workflowName: String? = null,
    ) {
        val inputData = buildInputData(
            taskId = taskId,
            action = action,
            connectionId = connectionId,
            command = command,
            apiKeyId = apiKeyId,
            snippetName = snippetName,
            workflowId = workflowId,
            workflowName = workflowName,
        )

        val request = OneTimeWorkRequestBuilder<SshTaskWorker>().apply {
            setInputData(inputData)
            addTag(TAG_SCHEDULED_TASK)
            addTag(taskId)
            if (delayMinutes > 0) {
                setInitialDelay(delayMinutes, TimeUnit.MINUTES)
            }
        }.build()

        workManager.enqueueUniqueWork(
            taskId,
            ExistingWorkPolicy.REPLACE,
            request,
        )

        Log.i(TAG, "Scheduled one-shot task '$taskId': delay=${delayMinutes}m, action=$action")
    }

    /**
     * Cancel a specific task by its unique work name.
     */
    fun cancelTask(taskId: String) {
        workManager.cancelUniqueWork(taskId)
        Log.i(TAG, "Cancelled task '$taskId'")
    }

    /**
     * Cancel all scheduled SSH tasks.
     */
    fun cancelAll() {
        workManager.cancelAllWorkByTag(TAG_SCHEDULED_TASK)
        Log.i(TAG, "Cancelled all scheduled tasks")
    }

    /**
     * Get information about all scheduled tasks.
     *
     * Returns a list of maps, each containing:
     *   - id: Work request UUID string
     *   - taskId: The unique work name tag
     *   - state: WorkInfo.State name (ENQUEUED, RUNNING, SUCCEEDED, etc.)
     *
     * A request's tags are the app's own, the task's id, and the worker's
     * class name, which WorkRequest.Builder adds to every request. WorkInfo
     * holds them in a HashSet, in no set order: the first tag that was not the
     * app's own was the class name for about three tasks in four, and an
     * orphaned job was then "cancelled" by a name no work has.
     */
    suspend fun getScheduledTasks(): List<Map<String, Any?>> {
        val workInfos = workManager.getWorkInfosByTagFlow(TAG_SCHEDULED_TASK).first()
        val workerTag = SshTaskWorker::class.java.name
        return workInfos.map { info ->
            val taskTag = info.tags.firstOrNull { it != TAG_SCHEDULED_TASK && it != workerTag }
            mapOf(
                "id" to info.id.toString(),
                "taskId" to (taskTag ?: "unknown"),
                "state" to info.state.name,
                "runAttemptCount" to info.runAttemptCount,
            )
        }
    }

    private fun buildInputData(
        taskId: String,
        action: String,
        connectionId: String,
        command: String?,
        apiKeyId: String,
        snippetName: String?,
        workflowId: String?,
        workflowName: String?,
    ): Data {
        return Data.Builder()
            // The app's id of the task: its run is written to it (its Last).
            .putString("task_id", taskId)
            .putString("action", action)
            .putString("connection_id", connectionId)
            .putString("api_key_id", apiKeyId)
            .apply {
                if (command != null) putString("command", command)
                if (snippetName != null) putString("snippet_name", snippetName)
                if (workflowId != null) putString("workflow_id", workflowId)
                if (workflowName != null) putString("workflow_name", workflowName)
            }
            .build()
    }

    companion object {
        private const val TAG = "TaskSchedulerManager"
        const val TAG_SCHEDULED_TASK = "zestssh_scheduled_task"
    }
}
