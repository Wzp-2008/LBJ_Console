package org.noxylva.lbjconsole.flutter

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

class ClassicSppChannelHandler private constructor(
    private val context: Context,
    private val channel: MethodChannel,
) : MethodChannel.MethodCallHandler {
    companion object {
        private const val CHANNEL = "lbjconsole/classic_spp"
        private val SPP_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")

        fun registerWith(engine: FlutterEngine, context: Context) {
            val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            channel.setMethodCallHandler(ClassicSppChannelHandler(context, channel))
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor = Executors.newCachedThreadPool()
    private val generation = AtomicInteger(0)
    private val writeLock = Any()

    @Volatile
    private var socket: BluetoothSocket? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "connect" -> connect(call.argument<String>("address"), result)
            "write" -> write(call.argument<ByteArray>("data"), result)
            "disconnect" -> {
                closeCurrentSocket()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    @SuppressLint("MissingPermission")
    private fun connect(address: String?, result: MethodChannel.Result) {
        if (address.isNullOrBlank()) {
            result.error("INVALID_ADDRESS", "缺少 Classic Bluetooth 设备地址", null)
            return
        }
        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val adapter: BluetoothAdapter? = manager?.adapter
        if (adapter == null || !adapter.isEnabled) {
            result.error("BLUETOOTH_OFF", "蓝牙未开启", null)
            return
        }
        val token = generation.incrementAndGet()
        closeSocketOnly()
        executor.execute {
            var candidate: BluetoothSocket? = null
            try {
                adapter.cancelDiscovery()
                val device = adapter.getRemoteDevice(address)
                candidate = device.createInsecureRfcommSocketToServiceRecord(SPP_UUID)
                socket = candidate
                candidate.connect()
                if (generation.get() != token) {
                    candidate.close()
                    return@execute
                }
                socket = candidate
                completeSuccess(result)
                readLoop(candidate, token)
            } catch (error: Exception) {
                try { candidate?.close() } catch (_: Exception) {}
                if (generation.get() == token) {
                    if (socket === candidate) socket = null
                    completeError(result, "SPP_CONNECT_FAILED", readableError(error))
                }
            }
        }
    }

    private fun readLoop(activeSocket: BluetoothSocket, token: Int) {
        executor.execute {
            val buffer = ByteArray(8192)
            try {
                while (generation.get() == token) {
                    val count = activeSocket.inputStream.read(buffer)
                    if (count < 0) break
                    if (count > 0) {
                        val data = buffer.copyOf(count)
                        mainHandler.post { channel.invokeMethod("data", data) }
                    }
                }
            } catch (error: IOException) {
                if (generation.get() == token) {
                    mainHandler.post { channel.invokeMethod("error", readableError(error)) }
                }
            } finally {
                if (generation.compareAndSet(token, token + 1)) {
                    socket = null
                    try { activeSocket.close() } catch (_: Exception) {}
                    mainHandler.post { channel.invokeMethod("disconnected", null) }
                }
            }
        }
    }

    private fun write(data: ByteArray?, result: MethodChannel.Result) {
        if (data == null || data.isEmpty()) {
            result.error("INVALID_DATA", "SPP 写入内容为空", null)
            return
        }
        val activeSocket = socket
        if (activeSocket == null || !activeSocket.isConnected) {
            result.error("NOT_CONNECTED", "Classic SPP 未连接", null)
            return
        }
        executor.execute {
            try {
                synchronized(writeLock) {
                    activeSocket.outputStream.write(data)
                    activeSocket.outputStream.flush()
                }
                completeSuccess(result)
            } catch (error: Exception) {
                completeError(result, "SPP_WRITE_FAILED", readableError(error))
            }
        }
    }

    private fun closeCurrentSocket() {
        generation.incrementAndGet()
        closeSocketOnly()
    }

    private fun closeSocketOnly() {
        val old = socket
        socket = null
        try { old?.close() } catch (_: Exception) {}
    }

    private fun completeSuccess(result: MethodChannel.Result) {
        mainHandler.post { result.success(null) }
    }

    private fun completeError(result: MethodChannel.Result, code: String, message: String) {
        mainHandler.post { result.error(code, message, null) }
    }

    private fun readableError(error: Exception): String =
        error.localizedMessage?.takeIf { it.isNotBlank() }
            ?: error.javaClass.simpleName
}
