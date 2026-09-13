package com.flutter_classic_bluetooth.flutter_classic_bluetooth

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothServerSocket as AndroidServerSocket
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import java.io.IOException
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger

class BluetoothServerSocketWrapper(
    val id: Int,
    private val adapter: BluetoothAdapter,
    private val uuid: String,
    private val serviceName: String,
    private val secure: Boolean,
    // Shared with the plugin (and client connects) so connection ids never collide.
    private val connectionIdSource: AtomicInteger,
    private val onConnectionAccepted: (BluetoothConnectionWrapper) -> Unit,
) {
    private var serverSocket: AndroidServerSocket? = null
    private var acceptThread: Thread? = null
    private var eventSink: EventChannel.EventSink? = null

    // EventSink calls and channel registration must run on the main thread.
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var running = false

    val streamHandler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
            eventSink = events
        }
        override fun onCancel(arguments: Any?) {
            eventSink = null
        }
    }

    @Suppress("MissingPermission")
    fun start() {
        val parsedUuid = UUID.fromString(uuid)

        serverSocket = if (secure) {
            adapter.listenUsingRfcommWithServiceRecord(serviceName, parsedUuid)
        } else {
            adapter.listenUsingInsecureRfcommWithServiceRecord(serviceName, parsedUuid)
        }

        running = true
        acceptThread = Thread {
            while (running) {
                try {
                    val socket = serverSocket?.accept() ?: break
                    val connId = connectionIdSource.getAndIncrement()
                    val deviceAddress = socket.remoteDevice.address
                    val connection = BluetoothConnectionWrapper(
                        id = connId,
                        socket = socket,
                        address = deviceAddress,
                    )
                    // Register the client's channels and notify Dart on the main thread.
                    mainHandler.post {
                        onConnectionAccepted(connection)
                        eventSink?.success(mapOf("id" to connId, "address" to deviceAddress))
                    }
                } catch (_: IOException) {
                    break
                }
            }
        }.apply {
            isDaemon = true
            name = "bt-server-$id"
            start()
        }
    }

    fun close() {
        running = false
        try { serverSocket?.close() } catch (_: IOException) {}
        serverSocket = null
        acceptThread?.interrupt()
        acceptThread = null
        eventSink = null
    }
}
