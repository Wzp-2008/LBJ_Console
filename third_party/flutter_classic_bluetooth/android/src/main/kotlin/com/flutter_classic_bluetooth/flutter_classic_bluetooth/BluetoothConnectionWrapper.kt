package com.flutter_classic_bluetooth.flutter_classic_bluetooth

import android.bluetooth.BluetoothSocket
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.atomic.AtomicBoolean

class BluetoothConnectionWrapper(
    val id: Int,
    private val socket: BluetoothSocket,
    val address: String,
) {
    private var readThread: Thread? = null
    private var dataEventSink: EventChannel.EventSink? = null
    private var stateEventSink: EventChannel.EventSink? = null

    // EventSink calls must happen on the main (platform) thread.
    private val mainHandler = Handler(Looper.getMainLooper())
    private val disconnectedEmitted = AtomicBoolean(false)

    @Volatile
    private var requestedClosing = false

    val isConnected: Boolean get() = socket.isConnected && !requestedClosing

    val inputStream: InputStream get() = socket.inputStream
    val outputStream: OutputStream get() = socket.outputStream

    val dataStreamHandler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
            dataEventSink = events
            startReading()
        }
        override fun onCancel(arguments: Any?) {
            dataEventSink = null
        }
    }

    val stateStreamHandler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
            stateEventSink = events
            events.success("connected")
        }
        override fun onCancel(arguments: Any?) {
            stateEventSink = null
        }
    }

    private fun startReading() {
        readThread = Thread {
            val buffer = ByteArray(1024)
            val input = try { inputStream } catch (_: IOException) { return@Thread }

            while (!requestedClosing) {
                try {
                    val bytesRead = input.read(buffer)
                    if (bytesRead == -1) break
                    val data = buffer.copyOf(bytesRead)
                    mainHandler.post { dataEventSink?.success(data) }
                } catch (_: IOException) {
                    break
                }
            }

            if (!requestedClosing) emitDisconnected()
        }.apply {
            isDaemon = true
            name = "bt-read-$id"
            start()
        }
    }

    /** Emits the terminal "disconnected" state exactly once, on the main thread. */
    private fun emitDisconnected() {
        if (!disconnectedEmitted.compareAndSet(false, true)) return
        mainHandler.post {
            stateEventSink?.success("disconnected")
            dataEventSink?.endOfStream()
        }
    }

    fun write(data: ByteArray) {
        try {
            outputStream.write(data)
            outputStream.flush()
        } catch (e: IOException) {
            throw IOException("Failed to write to connection $id: ${e.message}")
        }
    }

    fun close() {
        requestedClosing = true
        emitDisconnected()
        try { socket.close() } catch (_: IOException) {}
        readThread?.interrupt()
        readThread = null
    }
}
