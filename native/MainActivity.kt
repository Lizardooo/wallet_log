package com.example.wallet_log

import android.Manifest
import android.content.pm.PackageManager
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Reads the SMS inbox for the Flutter side; replaces a third-party SMS plugin. */
class MainActivity : FlutterActivity() {
    private val channelName = "wallet_log/sms"
    private var pending: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestPermission" -> requestPerm(result)
                    "readInbox" -> readInbox(result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun hasPerm(): Boolean =
        checkSelfPermission(Manifest.permission.READ_SMS) == PackageManager.PERMISSION_GRANTED

    private fun requestPerm(result: MethodChannel.Result) {
        if (hasPerm()) {
            result.success(true)
            return
        }
        pending = result
        requestPermissions(arrayOf(Manifest.permission.READ_SMS), 77)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 77) {
            pending?.success(
                grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            )
            pending = null
        }
    }

    private fun readInbox(result: MethodChannel.Result) {
        if (!hasPerm()) {
            result.error("denied", "READ_SMS not granted", null)
            return
        }
        Thread {
            val out = ArrayList<Map<String, Any?>>()
            try {
                contentResolver.query(
                    Uri.parse("content://sms/inbox"),
                    arrayOf("address", "body", "date"),
                    null,
                    null,
                    "date DESC"
                )?.use { c ->
                    while (c.moveToNext()) {
                        out.add(
                            mapOf(
                                "address" to c.getString(0),
                                "body" to c.getString(1),
                                "date" to c.getLong(2)
                            )
                        )
                    }
                }
                runOnUiThread { result.success(out) }
            } catch (e: Exception) {
                runOnUiThread { result.error("read", e.message, null) }
            }
        }.start()
    }
}
