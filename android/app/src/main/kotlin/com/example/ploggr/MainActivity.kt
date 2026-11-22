package com.example.ploggr

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec

class MainActivity : FlutterActivity() {
    private var notificationRequest: MethodChannel.Result? = null
    private val notificationRequestCode = 8271

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == notificationRequestCode) {
            notificationRequest?.success(null)
            notificationRequest = null
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "ploggr/tracking").setMethodCallHandler { call, result ->
            val prefs = getSharedPreferences("tracking_notifications", MODE_PRIVATE)
            when {
                call.method != "requestNotification" -> result.notImplemented()
                Build.VERSION.SDK_INT < 33 || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                    PackageManager.PERMISSION_GRANTED || prefs.getBoolean("asked", false) -> result.success(null)
                else -> {
                    prefs.edit().putBoolean("asked", true).apply()
                    notificationRequest = result
                    requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), notificationRequestCode)
                }
            }
        }
        val channel = MethodChannel(
            messenger, "ploggr/session-storage", StandardMethodCodec.INSTANCE,
            messenger.makeBackgroundTaskQueue(),
        )
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "flush" -> {
                    // Wait for the secure storage plugin's encrypted apply() to reach disk.
                    val prefs = getSharedPreferences("ploggr_sessions", MODE_PRIVATE)
                    if (prefs.edit().commit()) result.success(null)
                    else result.error("storage_write", "Could not persist session change", null)
                }
                "isLogoutPending", "setLogoutPending" -> {
                    // A boolean survives process death even when encrypted storage cannot be opened.
                    val scope = call.argument<String>("scope")
                    if (scope == null) {
                        result.error("missing_scope", "Missing API scope", null)
                        return@setMethodCallHandler
                    }
                    val prefs = getSharedPreferences("ploggr_session_lifecycle", MODE_PRIVATE)
                    if (call.method == "isLogoutPending") {
                        result.success(prefs.getBoolean(scope, false))
                    } else {
                        val editor = prefs.edit()
                        if (call.argument<Boolean>("pending") == true) editor.putBoolean(scope, true)
                        else editor.remove(scope)
                        if (editor.commit()) result.success(null)
                        else result.error("storage_write", "Could not persist logout status", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
