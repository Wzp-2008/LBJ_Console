package com.flutter_classic_bluetooth.flutter_classic_bluetooth.receivers

import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import com.flutter_classic_bluetooth.flutter_classic_bluetooth.BluetoothHelper
import io.flutter.plugin.common.EventChannel

class BondStateReceiver(private val context: Context) : EventChannel.StreamHandler {
    private var receiver: BroadcastReceiver? = null

    @Suppress("MissingPermission")
    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        // Only emit changes for the requested device, if an address was given.
        val targetAddress = (arguments as? Map<*, *>)?.get("address") as? String

        receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                if (intent.action == BluetoothDevice.ACTION_BOND_STATE_CHANGED) {
                    val device = intent.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE)
                        ?: return
                    if (targetAddress != null && device.address != targetAddress) return
                    val state = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.BOND_NONE)
                    events.success(BluetoothHelper.bondStateToString(state))
                }
            }
        }
        BluetoothHelper.registerExportedReceiver(
            context, receiver!!, IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
        )
        // Emit the current bond state of the requested device as a snapshot.
        if (targetAddress != null) {
            try {
                val adapter = (context.getSystemService(Context.BLUETOOTH_SERVICE)
                        as? BluetoothManager)?.adapter
                val device = adapter?.getRemoteDevice(targetAddress)
                if (device != null) {
                    events.success(BluetoothHelper.bondStateToString(device.bondState))
                }
            } catch (_: IllegalArgumentException) {
                // Invalid address, skip the snapshot.
            } catch (_: SecurityException) {
                // Missing permission, skip the snapshot.
            }
        }
    }

    override fun onCancel(arguments: Any?) {
        receiver?.let { context.unregisterReceiver(it) }
        receiver = null
    }
}
