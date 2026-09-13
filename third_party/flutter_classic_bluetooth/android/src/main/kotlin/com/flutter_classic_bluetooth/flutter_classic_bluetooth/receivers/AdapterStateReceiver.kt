package com.flutter_classic_bluetooth.flutter_classic_bluetooth.receivers

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import com.flutter_classic_bluetooth.flutter_classic_bluetooth.BluetoothHelper
import io.flutter.plugin.common.EventChannel

class AdapterStateReceiver(private val context: Context) : EventChannel.StreamHandler {
    private var receiver: BroadcastReceiver? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                if (intent.action == BluetoothAdapter.ACTION_STATE_CHANGED) {
                    val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)
                    events.success(BluetoothHelper.adapterStateToString(state))
                }
            }
        }
        BluetoothHelper.registerExportedReceiver(
            context, receiver!!, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
        )
        // Emit the current adapter state immediately so listeners get a snapshot
        // without waiting for the next change.
        val adapter = (context.getSystemService(Context.BLUETOOTH_SERVICE)
                as? BluetoothManager)?.adapter
        events.success(
            if (adapter == null) "unsupported"
            else BluetoothHelper.adapterStateToString(adapter.state)
        )
    }

    override fun onCancel(arguments: Any?) {
        receiver?.let { context.unregisterReceiver(it) }
        receiver = null
    }
}
