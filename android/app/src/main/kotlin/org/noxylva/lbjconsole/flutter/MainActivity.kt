package org.noxylva.lbjconsole.flutter

import android.content.Intent
import androidx.core.content.FileProvider
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val updateChannel = "lbjconsole/updater"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        RtlTcpChannelHandler.registerWith(flutterEngine)
        AudioInputHandler.registerWith(flutterEngine, applicationContext)
        ClassicSppChannelHandler.registerWith(flutterEngine, applicationContext)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, updateChannel)
            .setMethodCallHandler { call, result ->
                if (call.method != "installApk") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("INVALID_PATH", "APK path is missing", null)
                    return@setMethodCallHandler
                }
                try {
                    val apk = File(path)
                    if (!apk.exists()) {
                        result.error("NOT_FOUND", "APK does not exist", null)
                        return@setMethodCallHandler
                    }
                    val uri = FileProvider.getUriForFile(
                        this,
                        "${applicationContext.packageName}.fileprovider",
                        apk,
                    )
                    val intent = Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(uri, "application/vnd.android.package-archive")
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    startActivity(intent)
                    result.success(null)
                } catch (error: Exception) {
                    result.error("INSTALLER_ERROR", error.message, null)
                }
            }
    }
}
