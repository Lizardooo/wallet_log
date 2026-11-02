package com.example.wallet_log

import android.Manifest
import android.annotation.SuppressLint
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.telephony.SubscriptionInfo
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Native side for the Flutter app: SMS inbox access and the daily reminder. */
class MainActivity : FlutterActivity() {
    private val channelName = "wallet_log/sms"
    private var pending: MethodChannel.Result? = null
    private var pendingSim = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestPermission" ->
                        requestPerm(Manifest.permission.READ_SMS, result)
                    "requestNotifPermission" ->
                        if (Build.VERSION.SDK_INT < 33) result.success(true)
                        else requestPerm("android.permission.POST_NOTIFICATIONS", result)
                    "readInbox" -> readInbox(result)
                    "requestPhoneState" -> requestSimPermissions(result)
                    "simInfo" -> result.success(simInfo())
                    "scheduleDaily" -> {
                        val h = call.argument<Int>("hour") ?: 9
                        val m = call.argument<Int>("minute") ?: 0
                        Reminder.schedule(applicationContext, h, m)
                        result.success(true)
                    }
                    "cancelDaily" -> {
                        Reminder.cancel(applicationContext)
                        result.success(true)
                    }
                    "getReminder" -> {
                        val s = Reminder.saved(applicationContext)
                        result.success(
                            if (s == null) null
                            else mapOf("hour" to s.first, "minute" to s.second)
                        )
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun hasPerm(perm: String): Boolean =
        checkSelfPermission(perm) == PackageManager.PERMISSION_GRANTED

    private fun requestPerm(perm: String, result: MethodChannel.Result) {
        requestPerms(arrayOf(perm), result, sim = false)
    }

    /**
     * The setup needs the subscription list (READ_PHONE_STATE) and, when the
     * carrier exposes it, the SIM's own number (READ_PHONE_NUMBERS). The number
     * is optional: the list is still useful without it, so success follows the
     * phone-state permission only.
     */
    private fun requestSimPermissions(result: MethodChannel.Result) {
        val perms = mutableListOf(Manifest.permission.READ_PHONE_STATE)
        if (Build.VERSION.SDK_INT >= 26) {
            perms.add(Manifest.permission.READ_PHONE_NUMBERS)
        }
        requestPerms(perms.toTypedArray(), result, sim = true)
    }

    private fun requestPerms(
        perms: Array<String>,
        result: MethodChannel.Result,
        sim: Boolean
    ) {
        val missing = perms.filter { !hasPerm(it) }
        if (missing.isEmpty()) {
            result.success(true)
            return
        }
        pending = result
        pendingSim = sim
        requestPermissions(missing.toTypedArray(), 77)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 77) {
            val result = pending
            val sim = pendingSim
            pending = null
            pendingSim = false
            result?.success(
                if (sim) {
                    hasPerm(Manifest.permission.READ_PHONE_STATE)
                } else {
                    grantResults.isNotEmpty() &&
                        grantResults.all { it == PackageManager.PERMISSION_GRANTED }
                }
            )
        }
    }

    /**
     * The phone's SIMs: which slot each one sits in, its carrier and the
     * subscription id that SMS rows carry. Used by the first-run setup so the
     * owner can say which SIM receives each wallet's messages.
     */
    private fun simInfo(): List<Map<String, Any?>> {
        if (!hasPerm(Manifest.permission.READ_PHONE_STATE)) return emptyList()
        if (Build.VERSION.SDK_INT < 22) return emptyList()
        val subs = try {
            SubscriptionManager.from(applicationContext).activeSubscriptionInfoList
        } catch (e: Exception) {
            null
        } ?: return emptyList()
        val sm = SubscriptionManager.from(applicationContext)
        return subs.sortedBy { if (it.simSlotIndex >= 0) it.simSlotIndex else Int.MAX_VALUE }
            .mapIndexed { index, s ->
                mapOf(
                    "subId" to s.subscriptionId,
                    "slot" to if (s.simSlotIndex >= 0) s.simSlotIndex else index,
                    "carrier" to (s.carrierName?.toString() ?: ""),
                    "number" to simNumber(sm, s)
                )
            }
    }

    /**
     * The SIM's own number, when the carrier wrote it on the card. Android 13+
     * has a dedicated API; older versions use the line-1 number or the
     * subscription record. Many Egyptian SIMs carry no number at all, in which
     * case null is returned and the setup asks the owner to type it.
     */
    @Suppress("DEPRECATION")
    @SuppressLint("MissingPermission", "HardwareIds")
    private fun simNumber(sm: SubscriptionManager, s: SubscriptionInfo): String? {
        val candidates = mutableListOf<() -> String?>()
        if (Build.VERSION.SDK_INT >= 33) {
            candidates.add { sm.getPhoneNumber(s.subscriptionId) }
        }
        if (Build.VERSION.SDK_INT >= 24) {
            candidates.add {
                getSystemService(TelephonyManager::class.java)
                    ?.createForSubscriptionId(s.subscriptionId)
                    ?.line1Number
            }
        }
        candidates.add { s.number }
        for (c in candidates) {
            val n = try {
                c()
            } catch (e: Exception) {
                null
            }
            if (!n.isNullOrBlank()) return n
        }
        return null
    }

    private fun readInbox(result: MethodChannel.Result) {
        if (!hasPerm(Manifest.permission.READ_SMS)) {
            result.error("denied", "READ_SMS not granted", null)
            return
        }
        Thread {
            val out = ArrayList<Map<String, Any?>>()
            try {
                val uri = Uri.parse("content://sms/inbox")
                // sub_id (which SIM received the message) is missing on some devices.
                var withSub = true
                var c: Cursor? = try {
                    contentResolver.query(
                        uri, arrayOf("address", "body", "date", "sub_id"),
                        null, null, "date DESC"
                    )
                } catch (e: Exception) {
                    null
                }
                if (c == null) {
                    withSub = false
                    c = contentResolver.query(
                        uri, arrayOf("address", "body", "date"),
                        null, null, "date DESC"
                    )
                }
                c?.use { cur ->
                    while (cur.moveToNext()) {
                        val sub: Int? =
                            if (withSub && !cur.isNull(3)) cur.getInt(3) else null
                        out.add(
                            mapOf(
                                "address" to cur.getString(0),
                                "body" to cur.getString(1),
                                "date" to cur.getLong(2),
                                "subId" to sub
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
