package com.affluentlabs.zestssh.scheduler

import android.content.Context
import android.util.Base64
import java.security.SecureRandom

/**
 * One-time launch tokens that prove an automation intent carrying an
 * `api_key_id` really originated from OUR OWN in-app scheduler
 * ([SshTaskWorker]), not from a third-party app.
 *
 * Why this exists: `MainActivity` is `exported=true` (deep links and Tasker need
 * to reach it), and it honours an `api_key_id` extra: the app checks a
 * scheduled run by that key's id alone (the key is there, not expired, and is
 * marked used). No secret is stored for a scheduled task and none is
 * substituted (the app keeps only each key's hash). An `api_key_id` is
 * therefore a bearer authenticator, and it lives in ordinary storage (the
 * WorkManager job DB and the scheduled_tasks row). Without a check, any
 * co-installed app that obtained a leaked id could fire an explicit intent at
 * the exported activity and get headless SSH execution.
 *
 * The scheduler [issue]s a random token into app-PRIVATE SharedPreferences (only
 * our UID can read it) and puts the token in the launch intent. On receipt
 * [consume] verifies it: a third-party can neither read the private prefs nor
 * forge a token, so its `api_key_id` is dropped. Tokens are single-use and
 * expire quickly, so a captured legit intent can't be replayed either.
 */
object ScheduledLaunchTokens {
    private const val PREFS = "scheduled_launch_tokens"
    private const val KEY = "tokens"
    const val TTL_MS = 5 * 60 * 1000L // 5 minutes
    private const val MAX = 32 // cap the pending set

    private val rng = SecureRandom()

    /**
     * Mint a token, persist it (app-private) with a short expiry ([ttlMs]),
     * and return it. A task that waits for the person's tap on its
     * notification (SshTaskWorker, where Android does not let the app start
     * itself) keeps its token as long as that notification is shown.
     */
    @Synchronized
    fun issue(context: Context, ttlMs: Long = TTL_MS): String {
        val bytes = ByteArray(32)
        rng.nextBytes(bytes)
        val token = Base64.encodeToString(
            bytes,
            Base64.NO_WRAP or Base64.URL_SAFE or Base64.NO_PADDING,
        )
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val now = System.currentTimeMillis()
        // Prune expired, add the new one, cap the set.
        val kept = (prefs.getStringSet(KEY, emptySet()) ?: emptySet())
            .filter { (it.substringAfterLast(':').toLongOrNull() ?: 0L) > now }
            .toMutableList()
        kept.add("$token:${now + ttlMs}")
        val capped = if (kept.size > MAX) kept.takeLast(MAX) else kept
        prefs.edit().putStringSet(KEY, capped.toSet()).commit()
        return token
    }

    /**
     * Verify [token] against the stored set. Returns true exactly once for a
     * valid, unexpired token, removing it so it can't be replayed. Returns false
     * for a null/empty/expired/unknown token.
     */
    @Synchronized
    fun consume(context: Context, token: String?): Boolean {
        if (token.isNullOrEmpty()) return false
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val now = System.currentTimeMillis()
        val current = prefs.getStringSet(KEY, emptySet()) ?: return false
        var matched = false
        val remaining = mutableSetOf<String>()
        for (entry in current) {
            val t = entry.substringBeforeLast(':')
            val exp = entry.substringAfterLast(':').toLongOrNull() ?: 0L
            if (exp <= now) continue // drop expired
            if (!matched && constantTimeEquals(t, token)) {
                matched = true // consume: do not re-add
            } else {
                remaining.add(entry)
            }
        }
        prefs.edit().putStringSet(KEY, remaining).commit()
        return matched
    }

    private fun constantTimeEquals(a: String, b: String): Boolean {
        val ab = a.toByteArray()
        val bb = b.toByteArray()
        if (ab.size != bb.size) return false
        var r = 0
        for (i in ab.indices) r = r or (ab[i].toInt() xor bb[i].toInt())
        return r == 0
    }
}
