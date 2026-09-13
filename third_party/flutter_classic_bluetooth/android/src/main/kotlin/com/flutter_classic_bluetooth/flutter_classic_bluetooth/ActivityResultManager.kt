package com.flutter_classic_bluetooth.flutter_classic_bluetooth

import android.app.Activity
import android.content.Intent
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

class ActivityResultManager : PluginRegistry.ActivityResultListener {
    companion object {
        const val REQUEST_ENABLE_BT = 29572
        const val REQUEST_DISCOVERABLE = 29573
    }

    private var pendingResult: MethodChannel.Result? = null
    var activity: Activity? = null

    fun startActivityForResult(intent: Intent, requestCode: Int, result: MethodChannel.Result) {
        val act = activity
        if (act == null) {
            result.error("bluetoothDisabled", "No activity available", null)
            return
        }
        // Only one system dialog can be outstanding; reject re-entrant requests
        // instead of orphaning the previous result's Future.
        if (pendingResult != null) {
            result.error("pendingOperation", "Another request is already in progress", null)
            return
        }
        pendingResult = result
        act.startActivityForResult(intent, requestCode)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_ENABLE_BT && requestCode != REQUEST_DISCOVERABLE) return false

        val result = pendingResult ?: return false
        pendingResult = null

        when (requestCode) {
            REQUEST_ENABLE_BT -> {
                result.success(resultCode == Activity.RESULT_OK)
            }
            REQUEST_DISCOVERABLE -> {
                result.success(resultCode != Activity.RESULT_CANCELED)
            }
        }
        return true
    }
}
