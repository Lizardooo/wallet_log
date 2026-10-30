package com.example.wallet_log

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Re-arms the daily reminder after the phone restarts. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) {
            Reminder.reschedule(context)
        }
    }
}
