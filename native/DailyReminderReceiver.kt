package com.example.wallet_log

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

class DailyReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channelId = "daily_opening"
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                NotificationChannel(
                    channelId, "رصيد بداية اليوم", NotificationManager.IMPORTANCE_HIGH
                )
            )
        }
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return
        val tap = PendingIntent.getActivity(
            context, 0, launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder =
            if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, channelId)
            else Notification.Builder(context)
        val n = builder
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("رصيد المحافظ الافتتاحي")
            .setContentText("افتح التطبيق وأدخل رصيد بداية اليوم لكل محفظة")
            .setContentIntent(tap)
            .setAutoCancel(true)
            .build()
        nm.notify(1001, n)
    }
}
