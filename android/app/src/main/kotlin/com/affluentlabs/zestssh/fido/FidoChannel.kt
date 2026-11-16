package com.affluentlabs.zestssh.fido

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.IsoDep
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * The phone's side of a FIDO2 security key (4.0): only what carries bytes.
 *
 * NFC gives one ISO 7816-4 exchange at a time (reader mode, IsoDep); USB one
 * 64 byte report at a time (the FIDO HID interface of a plugged-in key, which
 * Android asks the person to allow). Everything that reads or writes a
 * meaning is in Dart (lib/services/fido/), where it is tested: nothing here
 * parses what a key sends.
 *
 * The channel is "zestssh/fido" (lib/services/fido/fido_platform.dart).
 * Errors carry a code Dart knows: cancelled, nfc_off, unavailable, denied,
 * lost, timeout.
 */
class FidoChannel(private val activity: Activity, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL)
    private val main = Handler(Looper.getMainLooper())

    // Exchanges block (a key that waits for a touch): never on the UI thread.
    // Reading and writing USB each have their own, so a Cancel can be written
    // while an answer is waited for.
    private val nfcIo: ExecutorService = Executors.newSingleThreadExecutor()
    private val usbReader: ExecutorService = Executors.newSingleThreadExecutor()
    private val usbWriter: ExecutorService = Executors.newSingleThreadExecutor()

    private var nfcWaiting: MethodChannel.Result? = null
    private var isoDep: IsoDep? = null

    private var usbConnection: UsbDeviceConnection? = null
    private var usbInterface: UsbInterface? = null
    private var usbIn: UsbEndpoint? = null
    private var usbOut: UsbEndpoint? = null
    private var usbAsking: MethodChannel.Result? = null
    private var usbAskedFor: UsbDevice? = null
    private var receiverRegistered = false

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "ways" -> result.success(ways())
            "nfcBegin" -> nfcBegin(result)
            "nfcTransceive" -> nfcTransceive(call.arguments as? ByteArray, result)
            "nfcEnd" -> {
                nfcEnd()
                result.success(null)
            }
            "usbOpen" -> usbOpen(result)
            "usbWrite" -> usbWrite(call.arguments as? ByteArray, result)
            "usbRead" -> usbRead((call.arguments as? Number)?.toInt() ?: 1000, result)
            "usbClose" -> {
                usbClose()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun ways(): Map<String, Boolean> {
        val adapter = nfcAdapter()
        return mapOf(
            "nfc" to (adapter != null),
            "nfcOn" to (adapter?.isEnabled == true),
            "usb" to activity.packageManager.hasSystemFeature(PackageManager.FEATURE_USB_HOST),
        )
    }

    // ── NFC ─────────────────────────────────────────────────────────────

    private fun nfcAdapter(): NfcAdapter? = try {
        NfcAdapter.getDefaultAdapter(activity)
    } catch (_: Exception) {
        null
    }

    /** Waits for a card that speaks ISO-DEP to be held to the phone. */
    private fun nfcBegin(result: MethodChannel.Result) {
        val adapter = nfcAdapter()
        if (adapter == null) {
            result.error("unavailable", "this device has no NFC", null)
            return
        }
        if (!adapter.isEnabled) {
            result.error("nfc_off", "NFC is switched off", null)
            return
        }
        nfcWaiting?.error("cancelled", "another wait took its place", null)
        nfcWaiting = result
        closeCard()
        val flags = NfcAdapter.FLAG_READER_NFC_A or
            NfcAdapter.FLAG_READER_NFC_B or
            NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK
        // The presence check is spaced out, so it does not cut into an exchange.
        val extras = Bundle().apply { putInt(NfcAdapter.EXTRA_READER_PRESENCE_CHECK_DELAY, 1000) }
        try {
            adapter.enableReaderMode(activity, { tag -> onTag(tag) }, flags, extras)
        } catch (e: Exception) {
            nfcWaiting = null
            result.error("unavailable", e.message, null)
        }
    }

    /** A card came into the field (called on a thread of the system's). */
    private fun onTag(tag: Tag) {
        val dep = IsoDep.get(tag) ?: return // not ISO-DEP: not a security key; keep waiting
        try {
            dep.connect()
            dep.timeout = EXCHANGE_TIMEOUT_MS
        } catch (_: Exception) {
            return // it left again at once: keep waiting
        }
        main.post {
            val waiting = nfcWaiting
            if (waiting == null) {
                closeQuietly(dep)
                return@post
            }
            nfcWaiting = null
            isoDep = dep
            waiting.success(null)
        }
    }

    private fun nfcTransceive(apdu: ByteArray?, result: MethodChannel.Result) {
        val dep = isoDep
        if (dep == null || apdu == null) {
            result.error("lost", "no security key in the field", null)
            return
        }
        nfcIo.execute {
            try {
                val answer = dep.transceive(apdu)
                main.post { result.success(answer) }
            } catch (e: Exception) {
                // TagLostException, IOException: the key left the field.
                main.post { result.error("lost", e.message, null) }
            }
        }
    }

    private fun closeCard() {
        val dep = isoDep ?: return
        isoDep = null
        nfcIo.execute { closeQuietly(dep) }
    }

    private fun closeQuietly(dep: IsoDep) {
        try {
            dep.close()
        } catch (_: Exception) {
        }
    }

    /** Stops waiting for a key and lets go of the one in the field. */
    private fun nfcEnd() {
        nfcWaiting?.error("cancelled", null, null)
        nfcWaiting = null
        closeCard()
        try {
            nfcAdapter()?.disableReaderMode(activity)
        } catch (_: Exception) {
            // (Not in front any more: Android has ended reader mode itself.)
        }
    }

    // ── USB ─────────────────────────────────────────────────────────────

    private fun usbManager(): UsbManager? = activity.getSystemService(Context.USB_SERVICE) as? UsbManager

    /**
     * Whether [itf] may be a security key's: HID, and neither a keyboard nor
     * a mouse (those say so with the boot subclass). Whether it is FIDO is
     * read from its report descriptor once the person has allowed the device.
     */
    private fun mayBeFido(itf: UsbInterface): Boolean =
        itf.interfaceClass == UsbConstants.USB_CLASS_HID && itf.interfaceSubclass == 0 && itf.interfaceProtocol == 0

    private fun candidate(manager: UsbManager): UsbDevice? =
        manager.deviceList.values.firstOrNull { device ->
            (0 until device.interfaceCount).any { mayBeFido(device.getInterface(it)) }
        }

    /** Opens the plugged-in security key: true, or false where none is plugged in. */
    private fun usbOpen(result: MethodChannel.Result) {
        if (usbConnection != null && usbIn != null && usbOut != null) {
            result.success(true)
            return
        }
        val manager = usbManager()
        val device = manager?.let { candidate(it) }
        if (manager == null || device == null) {
            result.success(false)
            return
        }
        if (manager.hasPermission(device)) {
            openDevice(manager, device, result)
            return
        }
        if (usbAsking != null) {
            // Android's question is already on screen: this ask says "not yet".
            result.success(false)
            return
        }
        usbAsking = result
        usbAskedFor = device
        registerReceiver()
        val mutable = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
        val intent = Intent(ACTION_USB_PERMISSION).setPackage(activity.packageName)
        manager.requestPermission(device, PendingIntent.getBroadcast(activity, 0, intent, mutable))
    }

    private val permissionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != ACTION_USB_PERMISSION) return
            val asking = usbAsking ?: return
            val device = usbAskedFor
            usbAsking = null
            usbAskedFor = null
            val manager = usbManager()
            // What Android now says of the device asked for, not what the broadcast claims.
            if (manager == null || device == null || !manager.hasPermission(device)) {
                asking.error("denied", "the security key was not allowed", null)
                return
            }
            openDevice(manager, device, asking)
        }
    }

    private fun registerReceiver() {
        if (receiverRegistered) return
        ContextCompat.registerReceiver(
            activity,
            permissionReceiver,
            IntentFilter(ACTION_USB_PERMISSION),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        receiverRegistered = true
    }

    /** Finds the FIDO interface of [device] by its report descriptor and claims it. */
    private fun openDevice(manager: UsbManager, device: UsbDevice, result: MethodChannel.Result) {
        usbWriter.execute {
            var opened: UsbDeviceConnection? = null
            try {
                val connection = manager.openDevice(device)
                if (connection == null) {
                    main.post { result.success(false) }
                    return@execute
                }
                opened = connection
                for (i in 0 until device.interfaceCount) {
                    val itf = device.getInterface(i)
                    if (!mayBeFido(itf) || !isFido(connection, itf)) continue
                    var input: UsbEndpoint? = null
                    var output: UsbEndpoint? = null
                    for (e in 0 until itf.endpointCount) {
                        val ep = itf.getEndpoint(e)
                        if (ep.type != UsbConstants.USB_ENDPOINT_XFER_INT) continue
                        if (ep.direction == UsbConstants.USB_DIR_IN) input = ep else output = ep
                    }
                    if (input == null || output == null) continue
                    if (!connection.claimInterface(itf, true)) continue
                    main.post {
                        usbClose()
                        usbConnection = connection
                        usbInterface = itf
                        usbIn = input
                        usbOut = output
                        result.success(true)
                    }
                    return@execute
                }
                // An HID device that is no security key.
                connection.close()
                main.post { result.success(false) }
            } catch (e: Exception) {
                try {
                    opened?.close()
                } catch (_: Exception) {
                }
                main.post { result.error("lost", e.message, null) }
            }
        }
    }

    /**
     * Whether [itf]'s HID report descriptor names the FIDO Alliance's usage
     * page (0xF1D0): the item 06 D0 F1.
     */
    private fun isFido(connection: UsbDeviceConnection, itf: UsbInterface): Boolean {
        val buffer = ByteArray(256)
        // GET_DESCRIPTOR (report), to the interface.
        val n = connection.controlTransfer(0x81, 0x06, 0x2200, itf.id, buffer, buffer.size, 1000)
        if (n < 3) return false
        for (i in 0..n - 3) {
            if (buffer[i] == 0x06.toByte() && buffer[i + 1] == 0xD0.toByte() && buffer[i + 2] == 0xF1.toByte()) return true
        }
        return false
    }

    private fun usbWrite(report: ByteArray?, result: MethodChannel.Result) {
        val connection = usbConnection
        val out = usbOut
        if (connection == null || out == null || report == null) {
            result.error("lost", "no security key is plugged in", null)
            return
        }
        usbWriter.execute {
            val n = try {
                connection.bulkTransfer(out, report, report.size, 2000)
            } catch (_: Exception) {
                -1
            }
            main.post {
                if (n == report.size) result.success(null) else result.error("lost", "the report was not taken", null)
            }
        }
    }

    private fun usbRead(timeoutMs: Int, result: MethodChannel.Result) {
        val connection = usbConnection
        val input = usbIn
        if (connection == null || input == null) {
            result.error("lost", "no security key is plugged in", null)
            return
        }
        usbReader.execute {
            val buffer = ByteArray(maxOf(REPORT_SIZE, input.maxPacketSize))
            val n = try {
                connection.bulkTransfer(input, buffer, buffer.size, timeoutMs.coerceIn(1, 120_000))
            } catch (_: Exception) {
                -1
            }
            main.post {
                if (n == REPORT_SIZE) {
                    result.success(buffer.copyOf(REPORT_SIZE))
                } else if (n < 0) {
                    // Nothing came in time, or the key was unplugged.
                    result.error("timeout", "no report came", null)
                } else {
                    result.error("lost", "a report of $n bytes", null)
                }
            }
        }
    }

    private fun usbClose() {
        val connection = usbConnection
        val itf = usbInterface
        usbConnection = null
        usbInterface = null
        usbIn = null
        usbOut = null
        if (connection != null) {
            try {
                if (itf != null) connection.releaseInterface(itf)
                connection.close()
            } catch (_: Exception) {
            }
        }
    }

    /** With the activity. */
    fun dispose() {
        channel.setMethodCallHandler(null)
        nfcEnd()
        usbAsking = null
        usbAskedFor = null
        usbClose()
        if (receiverRegistered) {
            try {
                activity.unregisterReceiver(permissionReceiver)
            } catch (_: Exception) {
            }
            receiverRegistered = false
        }
        nfcIo.shutdown()
        usbReader.shutdown()
        usbWriter.shutdown()
    }

    private companion object {
        const val CHANNEL = "zestssh/fido"
        const val ACTION_USB_PERMISSION = "zestssh.fido.USB_PERMISSION"
        const val REPORT_SIZE = 64

        /** One exchange with a card: a key that makes a key takes a second or two. */
        const val EXCHANGE_TIMEOUT_MS = 8000
    }
}
