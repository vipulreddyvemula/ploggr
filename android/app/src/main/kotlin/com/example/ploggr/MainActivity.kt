package com.example.ploggr

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
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
