package com.avtarcook.avtar_pos

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/// Android USB-OTG bridge for generic ESC/POS printer-class/serial devices.
/// The phone asks once for USB permission, then Dart sends the same RAW bytes
/// used by the Windows RP80US path.
class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "avtar_pos/raw_printer"
        private const val UPDATER_CHANNEL = "avtar_pos/updater"
        private const val ACTION_USB_PERMISSION = "com.avtarcook.avtar_pos.USB_PERMISSION"
    }

    private lateinit var usbManager: UsbManager
    private var pending: PendingPrint? = null
    private var receiverRegistered = false

    private data class PendingPrint(
        val device: UsbDevice,
        val usbInterface: UsbInterface,
        val endpoint: UsbEndpoint,
        val bytes: ByteArray,
        val result: MethodChannel.Result,
    )

    private val permissionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != ACTION_USB_PERMISSION) return
            val request = pending ?: return
            pending = null
            if (!intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)) {
                request.result.error("USB_PERMISSION_DENIED", "USB printer permission was denied.", null)
                return
            }
            writeRaw(request)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        usbManager = getSystemService(Context.USB_SERVICE) as UsbManager
        registerPermissionReceiver()
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result -> handlePrinterCall(call, result) }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, UPDATER_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "installApk") {
                    try {
                        val path = call.argument<String>("path") ?: throw IllegalArgumentException("No APK path supplied.")
                        val apk = File(path).canonicalFile
                        require(apk.path.startsWith(cacheDir.canonicalPath + File.separator) &&
                            apk.isFile && apk.extension == "apk") { "Invalid update APK path." }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                            !packageManager.canRequestPackageInstalls()) {
                            startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName")))
                        } else {
                            val uri = FileProvider.getUriForFile(this, "$packageName.updates", apk)
                            startActivity(Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, "application/vnd.android.package-archive")
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            })
                        }
                        result.success(true)
                    } catch (error: Exception) {
                        result.error("INSTALL_APK_FAILED", error.message, null)
                    }
                    return@setMethodCallHandler
                }
                if (call.method != "openUrl") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val url = call.argument<String>("url")
                if (url.isNullOrBlank()) {
                    result.error("INVALID_URL", "No update URL was supplied.", null)
                    return@setMethodCallHandler
                }
                try {
                    startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                    result.success(true)
                } catch (error: Exception) {
                    result.error("OPEN_URL_FAILED", error.message, null)
                }
            }
    }

    private fun handlePrinterCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "printUsbRaw") {
            result.notImplemented()
            return
        }
        val bytes = call.argument<ByteArray>("data")
        if (bytes == null || bytes.isEmpty()) {
            result.error("EMPTY_PRINT", "No ESC/POS data was supplied.", null)
            return
        }
        if (pending != null) {
            result.error("USB_BUSY", "A USB print request is already waiting for permission.", null)
            return
        }
        val target = findUsbTarget()
        if (target == null) {
            result.success(false)
            return
        }
        val request = PendingPrint(target.first, target.second, target.third, bytes, result)
        if (!usbManager.hasPermission(request.device)) {
            pending = request
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
            val permissionIntent = PendingIntent.getBroadcast(this, 0, Intent(ACTION_USB_PERMISSION), flags)
            usbManager.requestPermission(request.device, permissionIntent)
            return
        }
        writeRaw(request)
    }

    private fun findUsbTarget(): Triple<UsbDevice, UsbInterface, UsbEndpoint>? {
        for (device in usbManager.deviceList.values) {
            for (index in 0 until device.interfaceCount) {
                val usbInterface = device.getInterface(index)
                for (endpointIndex in 0 until usbInterface.endpointCount) {
                    val endpoint = usbInterface.getEndpoint(endpointIndex)
                    if (endpoint.direction == UsbConstants.USB_DIR_OUT &&
                        endpoint.type == UsbConstants.USB_ENDPOINT_XFER_BULK
                    ) {
                        return Triple(device, usbInterface, endpoint)
                    }
                }
            }
        }
        return null
    }

    private fun writeRaw(request: PendingPrint) {
        Thread {
            try {
                val connection = usbManager.openDevice(request.device)
                    ?: throw IllegalStateException("Could not open the USB printer.")
                try {
                    if (!connection.claimInterface(request.usbInterface, true)) {
                        throw IllegalStateException("Could not claim the USB printer interface.")
                    }
                    var offset = 0
                    while (offset < request.bytes.size) {
                        val length = minOf(12 * 1024, request.bytes.size - offset)
                        val written = connection.bulkTransfer(request.endpoint, request.bytes, offset, length, 5000)
                        if (written <= 0) throw IllegalStateException("The USB printer did not accept the print data.")
                        offset += written
                    }
                    runOnUiThread { request.result.success(true) }
                } finally {
                    connection.releaseInterface(request.usbInterface)
                    connection.close()
                }
            } catch (error: Exception) {
                runOnUiThread { request.result.error("USB_PRINT_FAILED", error.message, null) }
            }
        }.start()
    }

    private fun registerPermissionReceiver() {
        if (receiverRegistered) return
        val filter = IntentFilter(ACTION_USB_PERMISSION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(permissionReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(permissionReceiver, filter)
        }
        receiverRegistered = true
    }

    override fun onDestroy() {
        if (receiverRegistered) unregisterReceiver(permissionReceiver)
        receiverRegistered = false
        super.onDestroy()
    }
}
