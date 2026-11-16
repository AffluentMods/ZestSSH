package com.affluentlabs.zestssh.passkeys

import android.app.Activity
import android.os.Build
import androidx.credentials.CreatePublicKeyCredentialRequest
import androidx.credentials.CreatePublicKeyCredentialResponse
import androidx.credentials.CredentialManager
import androidx.credentials.GetCredentialRequest
import androidx.credentials.GetPublicKeyCredentialOption
import androidx.credentials.PublicKeyCredential
import androidx.credentials.exceptions.CreateCredentialCancellationException
import androidx.credentials.exceptions.CreateCredentialException
import androidx.credentials.exceptions.CreateCredentialNoCreateOptionException
import androidx.credentials.exceptions.CreateCredentialProviderConfigurationException
import androidx.credentials.exceptions.CreateCredentialUnsupportedException
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.GetCredentialException
import androidx.credentials.exceptions.GetCredentialProviderConfigurationException
import androidx.credentials.exceptions.GetCredentialUnsupportedException
import androidx.credentials.exceptions.NoCredentialException
import androidx.credentials.exceptions.domerrors.AbortError
import androidx.credentials.exceptions.domerrors.ConstraintError
import androidx.credentials.exceptions.domerrors.DomError
import androidx.credentials.exceptions.domerrors.InvalidStateError
import androidx.credentials.exceptions.domerrors.NotAllowedError
import androidx.credentials.exceptions.domerrors.NotSupportedError
import androidx.credentials.exceptions.domerrors.SecurityError
import androidx.credentials.exceptions.domerrors.TimeoutError
import androidx.credentials.exceptions.publickeycredential.CreatePublicKeyCredentialDomException
import androidx.credentials.exceptions.publickeycredential.GetPublicKeyCredentialDomException
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * The phone's own passkeys (3.3; the two-step contract, section 4), on the
 * channel zestssh/passkeys (lib/services/passkeys/channel_passkeys.dart):
 * Credential Manager makes and uses them, with Google Play services'
 * provider on Android 9 to 13 and the system's own from Android 14.
 *
 * ZestSSH Cloud's options come in as JSON text and go to the system as they
 * are; the system's response JSON goes back as text. The origin in its
 * clientDataJSON is android:apk-key-hash:<the signing key's SHA-256>,
 * written by the system for this app (each signing key is in the server's
 * PASSKEY_ORIGINS and in zestssh.com/.well-known/assetlinks.json).
 *
 * A failure is answered as an error whose code the Dart side knows
 * (cancelled, no-credential, invalid-state, security, unsupported, failed)
 * and whose message is the exception's type, for Copy details.
 */
class PasskeyChannel(private val activity: Activity, messenger: BinaryMessenger) {
    companion object {
        const val CHANNEL = "zestssh/passkeys"
    }

    private val channel = MethodChannel(messenger, CHANNEL)
    private val scope = MainScope()

    // One ceremony at a time: the system shows one sheet.
    private var busy = false

    init {
        channel.setMethodCallHandler(::onMethodCall)
    }

    /** Ends what is open with the activity. */
    fun dispose() {
        channel.setMethodCallHandler(null)
        scope.cancel()
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> result.success(available())
            "create" -> ceremony(call, result, create = true)
            "get" -> ceremony(call, result, create = false)
            else -> result.notImplemented()
        }
    }

    /**
     * Android 9 or later where Credential Manager can make passkeys: from
     * Android 14 the system's own; before it, Google Play services' provider,
     * which needs Google Play services on the phone.
     */
    private fun available(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return true
        return GoogleApiAvailability.getInstance()
            .isGooglePlayServicesAvailable(activity) == ConnectionResult.SUCCESS
    }

    private fun ceremony(call: MethodCall, result: MethodChannel.Result, create: Boolean) {
        val options = call.argument<String>("options")
        if (options.isNullOrEmpty()) {
            result.error("failed", "no options", null)
            return
        }
        if (!available()) {
            result.error("unsupported", "Android ${Build.VERSION.SDK_INT}", null)
            return
        }
        if (busy) {
            result.error("failed", "another passkey sheet is open", null)
            return
        }
        busy = true
        scope.launch {
            try {
                val json = if (create) create(options) else get(options)
                result.success(json)
            } catch (e: CancellationException) {
                // The activity went: the Dart side hears the sheet closed.
                result.error("cancelled", null, null)
                throw e
            } catch (e: CreateCredentialException) {
                val (code, detail) = failureOf(e)
                result.error(code, detail, null)
            } catch (e: GetCredentialException) {
                val (code, detail) = failureOf(e)
                result.error(code, detail, null)
            } catch (e: Exception) {
                // The request's JSON refused before any sheet (an
                // IllegalArgumentException), or anything else: its kind
                // only, never its words, which may quote the request.
                result.error("failed", e.javaClass.name, null)
            } finally {
                busy = false
            }
        }
    }

    /** Makes a passkey for the registration [options]; its RegistrationResponseJSON. */
    private suspend fun create(options: String): String {
        val response = CredentialManager.create(activity)
            .createCredential(activity, CreatePublicKeyCredentialRequest(options))
        if (response !is CreatePublicKeyCredentialResponse) {
            throw IllegalStateException("not a public key credential")
        }
        return response.registrationResponseJson
    }

    /** Uses a passkey for the sign-in [options]; its AuthenticationResponseJSON. */
    private suspend fun get(options: String): String {
        val request = GetCredentialRequest(listOf(GetPublicKeyCredentialOption(options)))
        val credential = CredentialManager.create(activity).getCredential(activity, request).credential
        if (credential !is PublicKeyCredential) throw IllegalStateException("not a public key credential")
        return credential.authenticationResponseJson
    }

    /** What making a passkey failed with, as the Dart side's code and the exception's type. */
    private fun failureOf(e: CreateCredentialException): Pair<String, String> = when (e) {
        is CreateCredentialCancellationException -> "cancelled" to e.type
        is CreatePublicKeyCredentialDomException -> codeOf(e.domError) to e.type
        is CreateCredentialNoCreateOptionException,
        is CreateCredentialProviderConfigurationException,
        is CreateCredentialUnsupportedException -> "unsupported" to e.type
        else -> "failed" to e.type
    }

    /** What using a passkey failed with, as the Dart side's code and the exception's type. */
    private fun failureOf(e: GetCredentialException): Pair<String, String> = when (e) {
        is GetCredentialCancellationException -> "cancelled" to e.type
        is NoCredentialException -> "no-credential" to e.type
        is GetPublicKeyCredentialDomException -> codeOf(e.domError) to e.type
        is GetCredentialProviderConfigurationException,
        is GetCredentialUnsupportedException -> "unsupported" to e.type
        else -> "failed" to e.type
    }

    /**
     * A WebAuthn DOM error as the Dart side's code: NotAllowedError (the
     * person closed the prompt, or it ran out), AbortError and TimeoutError
     * are a cancel, as a browser has them; InvalidStateError is a passkey of
     * the account this phone or key holds already; SecurityError is this app
     * not let make passkeys for zestssh.com (its signing key not in
     * assetlinks.json).
     */
    private fun codeOf(error: DomError): String = when (error) {
        is NotAllowedError, is AbortError, is TimeoutError -> "cancelled"
        is InvalidStateError -> "invalid-state"
        is SecurityError -> "security"
        is NotSupportedError, is ConstraintError -> "unsupported"
        else -> "failed"
    }
}
