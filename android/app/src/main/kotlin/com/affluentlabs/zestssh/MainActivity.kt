package com.affluentlabs.zestssh

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.os.Bundle
import android.view.KeyEvent
import com.affluentlabs.zestssh.fido.FidoChannel
import com.affluentlabs.zestssh.passkeys.PasskeyChannel
import com.affluentlabs.zestssh.scheduler.ScheduledLaunchTokens
import com.affluentlabs.zestssh.scheduler.TaskSchedulerManager
import com.affluentlabs.zestssh.widget.QuickConnectWidget
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

// FlutterFragmentActivity is required for RevenueCat paywall sheets
// and other bottom-sheet based UI on Android.
class MainActivity : FlutterFragmentActivity() {
    private val CHANNEL = "com.affluentlabs.zestssh/deeplink"
    private val VOLUME_CHANNEL = "com.affluentlabs.zestssh/volume_keys"
    private val FOREGROUND_CHANNEL = "com.affluentlabs.zestssh/foreground"
    private val SCHEDULER_CHANNEL = "com.affluentlabs.zestssh/scheduler"
    private var methodChannel: MethodChannel? = null
    private var initialLink: String? = null
    private lateinit var schedulerManager: TaskSchedulerManager

    // Whether volume key interception is active (set from Flutter side).
    private var interceptVolumeKeys = false

    // EventChannel sink for sending volume key events to Flutter.
    private var volumeEventSink: EventChannel.EventSink? = null

    // The phone's own passkeys (3.3), on zestssh/passkeys.
    private var passkeys: PasskeyChannel? = null
    private var fido: FidoChannel? = null

    // Automation intent action constants
    companion object {
        private const val ACTION_CONNECT = "com.affluentlabs.zestssh.CONNECT"
        private const val ACTION_OPEN = "com.affluentlabs.zestssh.OPEN"
        private const val ACTION_EXECUTE = "com.affluentlabs.zestssh.EXECUTE"
        private const val ACTION_SNIPPET = "com.affluentlabs.zestssh.SNIPPET"
        private const val ACTION_BATCH = "com.affluentlabs.zestssh.BATCH"
        private const val ACTION_WORKFLOW = "com.affluentlabs.zestssh.WORKFLOW"

        // The intent actions that legitimately launch an automation for a
        // result. Used to bind setAutomationResult() to the launching intent.
        private val AUTOMATION_ACTIONS = setOf(
            ACTION_CONNECT, ACTION_OPEN, ACTION_EXECUTE,
            ACTION_SNIPPET, ACTION_BATCH, ACTION_WORKFLOW,
        )
    }

    // Pending automation result intent for Tasker (set via method channel from Flutter)
    private var pendingAutomationResultIntent: Intent? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // NOTE: FLAG_SECURE used to be set here, blocking ALL screenshots
        // and screen recording app-wide. That was too aggressive: it
        // breaks legitimate use cases (sharing terminal output with a
        // coworker, accessibility tools, demoing the app on a call) and
        // users explicitly asked for it to go. If we later want to
        // protect specific high-sensitivity screens (private keys, etc),
        // we can scope FLAG_SECURE to those routes only.

        // Capture initial deep link before super.onCreate. An activity
        // opened again from Recents, or made again after Android ended the
        // app (savedInstanceState), is handed the intent it was first
        // started with: its link and its automation were answered then, and
        // are not again (found 16 October 2026 in a security
        // review: an automation the app was started for ran again each time).
        launchAnswered = savedInstanceState != null || launchedFromHistory(intent)
        initialLink = if (launchAnswered) null else intent?.data?.toString()
        super.onCreate(savedInstanceState)
        // Handle automation intent on cold start (engine not ready yet,
        // so we defer until configureFlutterEngine sends it)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Deep link method channel
        methodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        )

        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialLink" -> result.success(initialLink)
                "getInitialAutomation" -> {
                    // Once only (the Dart side keeps what it is given: asked
                    // again as it starts over after a failure, a scheduled
                    // launch's token was spent and its key lost), and never
                    // for a launch answered before (launchAnswered).
                    val automationData = if (launchAnswered) null else buildAutomationPayload(intent)
                    launchAnswered = true
                    result.success(automationData)
                }
                "setAutomationResult" -> {
                    val stdout = call.argument<String>("stdout") ?: ""
                    val exitCode = call.argument<Int>("exit_code") ?: 0
                    // Only return command output to a caller that actually
                    // launched us FOR a result (startActivityForResult, e.g.
                    // Tasker) via a recognized automation intent. WorkManager-
                    // and deep-link-originated automations have no calling
                    // activity waiting on a result, so handing them stdout
                    // would leak command output to an unrelated caller and
                    // isn't bound to the intent that authenticated. In those
                    // cases we skip setResult entirely.
                    val launchedForResult = callingActivity != null
                    val boundToAutomation = intent?.action in AUTOMATION_ACTIONS
                    if (launchedForResult && boundToAutomation) {
                        val resultIntent = Intent().apply {
                            putExtra("stdout", stdout)
                            putExtra("exit_code", exitCode)
                        }
                        setResult(
                            if (exitCode == 0) Activity.RESULT_OK else Activity.RESULT_CANCELED,
                            resultIntent
                        )
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // Volume keys method channel (for enabling/disabling interception)
        val volumeMethodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            VOLUME_CHANNEL
        )

        volumeMethodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "setEnabled" -> {
                    interceptVolumeKeys = call.argument<Boolean>("enabled") ?: false
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // Foreground service method channel
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FOREGROUND_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "startService" -> {
                    val count = call.argument<Int>("count") ?: 1
                    val names = ArrayList(call.argument<List<String>>("names") ?: emptyList())
                    val intent = Intent(this, SshForegroundService::class.java).apply {
                        putExtra(SshForegroundService.EXTRA_COUNT, count)
                        putStringArrayListExtra(SshForegroundService.EXTRA_NAMES, names)
                    }
                    startForegroundService(intent)
                    result.success(null)
                }
                "updateCount" -> {
                    val count = call.argument<Int>("count") ?: 1
                    val intent = Intent(this, SshForegroundService::class.java).apply {
                        action = SshForegroundService.ACTION_UPDATE_COUNT
                        putExtra(SshForegroundService.EXTRA_COUNT, count)
                    }
                    startService(intent)
                    result.success(null)
                }
                "stopService" -> {
                    stopService(Intent(this, SshForegroundService::class.java))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // Widget refresh method channel
        val widgetChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.affluentlabs.zestssh/widget"
        )
        widgetChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "updateWidget" -> {
                    val intent = Intent(this, QuickConnectWidget::class.java).apply {
                        action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
                    }
                    val ids = AppWidgetManager.getInstance(this)
                        .getAppWidgetIds(ComponentName(this, QuickConnectWidget::class.java))
                    intent.putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
                    sendBroadcast(intent)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // ── Task Scheduler method channel ─────────────────────────
        schedulerManager = TaskSchedulerManager(this)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SCHEDULER_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "scheduleTask" -> {
                    val taskId = call.argument<String>("taskId") ?: return@setMethodCallHandler result.error("INVALID", "taskId required", null)
                    val action = call.argument<String>("action") ?: "execute"
                    val connectionId = call.argument<String>("connectionId") ?: ""
                    val command = call.argument<String>("command")
                    val apiKeyId = call.argument<String>("apiKeyId") ?: return@setMethodCallHandler result.error("INVALID", "apiKeyId required", null)
                    val intervalMinutes = call.argument<Int>("intervalMinutes")?.toLong() ?: 15L
                    val initialDelayMinutes = call.argument<Int>("initialDelayMinutes")?.toLong() ?: 0L
                    val snippetName = call.argument<String>("snippetName")
                    val workflowId = call.argument<String>("workflowId")
                    val workflowName = call.argument<String>("workflowName")

                    schedulerManager.scheduleTask(
                        taskId = taskId,
                        action = action,
                        connectionId = connectionId,
                        command = command,
                        apiKeyId = apiKeyId,
                        intervalMinutes = intervalMinutes,
                        initialDelayMinutes = initialDelayMinutes,
                        snippetName = snippetName,
                        workflowId = workflowId,
                        workflowName = workflowName,
                    )
                    result.success(null)
                }
                "scheduleOneShot" -> {
                    val taskId = call.argument<String>("taskId") ?: return@setMethodCallHandler result.error("INVALID", "taskId required", null)
                    val action = call.argument<String>("action") ?: "execute"
                    val connectionId = call.argument<String>("connectionId") ?: ""
                    val command = call.argument<String>("command")
                    val apiKeyId = call.argument<String>("apiKeyId") ?: return@setMethodCallHandler result.error("INVALID", "apiKeyId required", null)
                    val delayMinutes = call.argument<Int>("delayMinutes")?.toLong() ?: 0L
                    val snippetName = call.argument<String>("snippetName")
                    val workflowId = call.argument<String>("workflowId")
                    val workflowName = call.argument<String>("workflowName")

                    schedulerManager.scheduleOneShot(
                        taskId = taskId,
                        action = action,
                        connectionId = connectionId,
                        command = command,
                        apiKeyId = apiKeyId,
                        delayMinutes = delayMinutes,
                        snippetName = snippetName,
                        workflowId = workflowId,
                        workflowName = workflowName,
                    )
                    result.success(null)
                }
                "cancelTask" -> {
                    val taskId = call.argument<String>("taskId") ?: return@setMethodCallHandler result.error("INVALID", "taskId required", null)
                    schedulerManager.cancelTask(taskId)
                    result.success(null)
                }
                "cancelAll" -> {
                    schedulerManager.cancelAll()
                    result.success(null)
                }
                "getScheduledTasks" -> {
                    CoroutineScope(Dispatchers.IO).launch {
                        try {
                            val tasks = schedulerManager.getScheduledTasks()
                            launch(Dispatchers.Main) { result.success(tasks) }
                        } catch (e: Exception) {
                            launch(Dispatchers.Main) { result.error("ERROR", e.message, null) }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Passkeys: Credential Manager makes and uses them in its own sheet,
        // over this activity (passkeys/PasskeyChannel.kt).
        passkeys?.dispose()
        passkeys = PasskeyChannel(this, flutterEngine.dartExecutor.binaryMessenger)

        // A FIDO2 security key held to the phone or plugged into it, for a key
        // that lives on one (fido/FidoChannel.kt): it carries bytes, no more.
        fido?.dispose()
        fido = FidoChannel(this, flutterEngine.dartExecutor.binaryMessenger)

        // Volume keys event channel (for sending key events to Flutter)
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "$VOLUME_CHANNEL/events"
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                volumeEventSink = events
            }

            override fun onCancel(arguments: Any?) {
                volumeEventSink = null
            }
        })
    }

    /**
     * Whether the link and the automation this activity was started with
     * were answered: handed to the Dart side, or answered before this
     * activity was made (Recents, or Android ending the app).
     */
    private var launchAnswered = false

    /**
     * Whether [intent] is the one this activity was first started with,
     * handed to it again because it was opened from Recents: it must not act
     * again.
     */
    private fun launchedFromHistory(intent: Intent?): Boolean =
        intent != null && (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0

    override fun onDestroy() {
        passkeys?.dispose()
        passkeys = null
        fido?.dispose()
        fido = null
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Forward deep links when app is already running
        val uri = intent.data?.toString()
        if (uri != null) {
            methodChannel?.invokeMethod("onDeepLink", uri)
        }
        // Forward automation intents when app is already running
        val automationData = buildAutomationPayload(intent)
        if (automationData != null) {
            methodChannel?.invokeMethod("onAutomation", automationData)
        }
    }

    /**
     * Builds a payload map from an automation intent, or returns null if the
     * intent does not carry a recognized automation action.
     *
     * Supported actions and their extras:
     *  - CONNECT:  connection_id | connection_label
     *              (ephemeral test connect: runs an `echo` and disconnects)
     *  - OPEN:     connection_id | connection_label
     *              (opens a real persistent SSH session and auto-starts any
     *              port-forward rules marked auto-start; the foreground
     *              service keeps the tunnels alive while the app runs)
     *  - EXECUTE:  connection_id | connection_label, command, timeout (optional)
     *  - SNIPPET:  connection_id | connection_label, snippet_name
     *  - BATCH:    connections (comma-separated), command, timeout (optional),
     *              parallel (optional, default true)
     */
    private fun buildAutomationPayload(intent: Intent?): Map<String, Any?>? {
        if (intent == null) return null
        val action = intent.action ?: return null

        val base = mutableMapOf<String, Any?>(
            "connection_id" to extraText(intent, "connection_id"),
            "connection_label" to extraText(intent, "connection_label"),
        )

        // api_key_id (from our scheduled WorkManager tasks) names the API key a
        // scheduled run uses. No secret is stored for it, and none is
        // substituted: the app keeps only each key's hash, and checks a
        // scheduled run by the key's id alone (there, not expired, marked
        // used). So the id is a BEARER authenticator, and this activity is
        // exported: honour it ONLY when accompanied by a valid one-time launch
        // token that our own in-app scheduler wrote to app-private storage. A
        // third-party app firing an explicit intent at this activity with a
        // leaked api_key_id cannot read or forge that token, so its id is
        // dropped and handleAutomation refuses the request (no key). The raw
        // `key` extra (Tasker, deep links) is unaffected: it is the user's own
        // credential, checked against the keys' hashes on the Flutter side.
        val apiKeyId = intent.getStringExtra("api_key_id")
        if (apiKeyId != null) {
            val launchToken = intent.getStringExtra("scheduled_launch_token")
            if (ScheduledLaunchTokens.consume(applicationContext, launchToken)) {
                base["api_key_id"] = apiKeyId
                // Which of the app's scheduled tasks this run is, so that
                // the app writes it to that task's Last: only from the
                // scheduler itself, as its key is.
                intent.getStringExtra("scheduled_task_id")?.let { base["scheduled_task_id"] = it }
            }
        }

        return when (action) {
            ACTION_CONNECT -> {
                base["action"] = "connect"
                val connectKey = extraText(intent, "key")
                if (connectKey != null) base["key"] = connectKey
                base
            }
            ACTION_OPEN -> {
                base["action"] = "open"
                val openKey = extraText(intent, "key")
                if (openKey != null) base["key"] = openKey
                // Optional: cap how long the action waits for the
                // session to reach `connected` before reporting back.
                extraText(intent, "timeout")?.toIntOrNull()?.let { base["timeout"] = it }
                base
            }
            ACTION_EXECUTE -> {
                base["action"] = "execute"
                base["command"] = extraText(intent, "command")
                val execKey = extraText(intent, "key")
                if (execKey != null) base["key"] = execKey
                extraText(intent, "timeout")?.toIntOrNull()?.let { base["timeout"] = it }
                // Output filter params
                val execGrep = extraText(intent, "grep")
                if (execGrep != null) base["grep"] = execGrep
                extraText(intent, "head")?.toIntOrNull()?.let { base["head"] = it }
                extraText(intent, "tail")?.toIntOrNull()?.let { base["tail"] = it }
                // Webhook callback
                val execCallback = extraText(intent, "callback")
                if (execCallback != null) base["callback"] = execCallback
                base
            }
            ACTION_SNIPPET -> {
                base["action"] = "snippet"
                base["snippet_name"] = extraText(intent, "snippet_name")
                val snippetKey = extraText(intent, "key")
                if (snippetKey != null) base["key"] = snippetKey
                // Extract all var_ prefixed extras as snippet variables.
                // e.g. intent extra "var_branch" with value "main" is forwarded
                // so the Dart side can substitute {{branch}} → "main".
                intent.extras?.let { extras ->
                    for (key in extras.keySet()) {
                        if (key.startsWith("var_") && key.length > 4) {
                            val value = extraText(intent, key)
                            if (value != null) {
                                base[key] = value
                            }
                        }
                    }
                }
                base
            }
            ACTION_WORKFLOW -> {
                base["action"] = "workflow"
                base["workflow_name"] = extraText(intent, "workflow_name")
                base["workflow_id"] = extraText(intent, "workflow_id")
                base["key"] = extraText(intent, "key")
                base
            }
            ACTION_BATCH -> {
                val payload = mutableMapOf<String, Any?>(
                    "action" to "batch",
                )
                val batchKey = extraText(intent, "key")
                if (batchKey != null) payload["key"] = batchKey
                // Split comma-separated connections into a List<String>:
                // "connections", as a batch link has them, or
                // "connection_ids", as the app's guide and the docs said
                // (it was not read, and such a batch reached no host).
                val connectionsRaw = extraText(intent, "connections")
                    ?: extraText(intent, "connection_ids") ?: ""
                val connectionIds = connectionsRaw
                    .split(",")
                    .map { it.trim() }
                    .filter { it.isNotEmpty() }
                payload["connection_ids"] = connectionIds
                payload["command"] = extraText(intent, "command")
                extraText(intent, "timeout")?.toIntOrNull()?.let { payload["timeout"] = it }
                extraText(intent, "parallel")?.toBooleanStrictOrNull()?.let { payload["parallel"] = it }
                // Output filter params
                val batchGrep = extraText(intent, "grep")
                if (batchGrep != null) payload["grep"] = batchGrep
                extraText(intent, "head")?.toIntOrNull()?.let { payload["head"] = it }
                extraText(intent, "tail")?.toIntOrNull()?.let { payload["tail"] = it }
                // Webhook callback
                val batchCallback = extraText(intent, "callback")
                if (batchCallback != null) payload["callback"] = batchCallback
                payload
            }
            else -> null
        }
    }

    /**
     * Extra [name] of [intent] as text, whatever type it came as. Tasker
     * sends a value that reads as a number as an Integer and true or false
     * as a Boolean, which getStringExtra gave as null: a head or tail count
     * was dropped, and a label of digits named no host; and a text "false"
     * for parallel was read as true.
     */
    @Suppress("DEPRECATION")
    private fun extraText(intent: Intent, name: String): String? =
        intent.extras?.get(name)?.toString()

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (interceptVolumeKeys && event.action == KeyEvent.ACTION_DOWN) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_VOLUME_UP -> {
                    volumeEventSink?.success("volume_up")
                    return true // Consume the event
                }
                KeyEvent.KEYCODE_VOLUME_DOWN -> {
                    volumeEventSink?.success("volume_down")
                    return true // Consume the event
                }
            }
        }
        return super.dispatchKeyEvent(event)
    }
}
