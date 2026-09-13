package org.noxylva.lbjconsole.flutter

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val updateChannel = "lbjconsole/updater"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                        !packageManager.canRequestPackageInstalls()) {
                        startActivity(
                            Intent(
                                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName"),
                            ),
                        )
                        result.error(
                            "UNKNOWN_SOURCES_DISABLED",
                            "请先允许本应用安装未知来源应用，然后重试",
                            null,
                        )
                        return@setMethodCallHandler
                    }
                    val apk = File(path)
                    if (!apk.exists()) {
                        result.error("NOT_FOUND", "APK does not exist", null)
                        return@setMethodCallHandler
                    }
                    // The Dart temp directory can resolve through a different
                    // canonical path on some Android builds.  Copy the APK to
                    // the app cache, which is explicitly exposed by our
                    // FileProvider, before creating the content URI.
                    val installApk = File(
                        cacheDir,
                        "lbj-update-${System.currentTimeMillis()}.apk",
                    )
                    apk.copyTo(installApk, overwrite = true)
                    val uri = FileProvider.getUriForFile(
                        this,
                        "${applicationContext.packageName}.fileprovider",
                        installApk,
                    )
                    val intent = Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(uri, "application/vnd.android.package-archive")
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    startActivity(intent)
                    result.success("installer_opened")
                } catch (error: Exception) {
                    result.error("INSTALLER_ERROR", error.message, null)
                }
            }
    }
}
