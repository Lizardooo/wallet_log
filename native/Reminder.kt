package com.example.wallet_log

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import java.util.Calendar

/** Schedules the daily "enter opening balances" notification. */
object Reminder {
    private const val PREFS = "wallet_log_reminder"

    private fun pendingIntent(ctx: Context): PendingIntent {
        val i = Intent(ctx, DailyReminderReceiver::class.java)
        return PendingIntent.getBroadcast(
            ctx, 4001, i,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    fun schedule(ctx: Context, hour: Int, minute: Int) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putInt("h", hour).putInt("m", minute).apply()
        val cal = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, hour)
            set(Calendar.MINUTE, minute)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        if (cal.timeInMillis <= System.currentTimeMillis()) {
            cal.add(Calendar.DAY_OF_YEAR, 1)
        }
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.setInexactRepeating(
            AlarmManager.RTC_WAKEUP, cal.timeInMillis,
            AlarmManager.INTERVAL_DAY, pendingIntent(ctx)
        )
    }

    fun cancel(ctx: Context) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply()
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.cancel(pendingIntent(ctx))
    }

    fun saved(ctx: Context): Pair<Int, Int>? {
        val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (!p.contains("h")) return null
        return Pair(p.getInt("h", 9), p.getInt("m", 0))
    }

    fun reschedule(ctx: Context) {
        val s = saved(ctx) ?: return
        schedule(ctx, s.first, s.second)
    }
}
