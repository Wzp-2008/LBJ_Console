package com.flutter_classic_bluetooth.flutter_classic_bluetooth.receivers

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import com.flutter_classic_bluetooth.flutter_classic_bluetooth.BluetoothHelper
import io.flutter.plugin.common.EventChannel

class DiscoveryStateReceiver(private val context: Context) : EventChannel.StreamHandler {
    private var receiver: BroadcastReceiver? = null

    @Suppress("MissingPermission")
    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                when (intent.action) {
                    BluetoothAdapter.ACTION_DISCOVERY_STARTED -> events.success(true)
                    BluetoothAdapter.ACTION_DISCOVERY_FINISHED -> events.success(false)
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(BluetoothAdapter.ACTION_DISCOVERY_STARTED)
            addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED)
        }
        BluetoothHelper.registerExportedReceiver(context, receiver!!, filter)
        // Emit the current discovery state as an initial snapshot.
        val discovering = try {
            (context.getSystemService(Context.BLUETOOTH_SERVICE)
                as? BluetoothManager)?.adapter?.isDiscovering == true
        } catch (_: SecurityException) {
            false
        }
        events.success(discovering)
    }

    override fun onCancel(arguments: Any?) {
        receiver?.let { context.unregisterReceiver(it) }
        receiver = null
    }
}
