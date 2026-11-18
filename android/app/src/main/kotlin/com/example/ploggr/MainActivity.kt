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
            if (call.method != "flush") {
                result.notImplemented()
            } else {
                // flutter_secure_storage uses apply(). Wait for its encrypted preferences
                // to reach disk before sending a one-time refresh or acknowledging logout.
                val prefs = getSharedPreferences("ploggr_sessions", MODE_PRIVATE)
                if (prefs.edit().commit()) result.success(null)
                else result.error("storage_write", "Could not persist session change", null)
            }
        }
    }
}
