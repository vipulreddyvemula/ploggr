package com.example.ploggr

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import androidx.core.content.pm.PackageInfoCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.io.File

class FieldUpdateFileProvider : FileProvider()

internal class FieldUpdateInstaller(private val activity: Activity) {
    fun register(messenger: BinaryMessenger) {
        MethodChannel(
            messenger, "ploggr/field-updates", StandardMethodCodec.INSTANCE,
            messenger.makeBackgroundTaskQueue(),
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "apkPath" -> {
                    val directory = updateDirectory()
                    if (!directory.isDirectory && !directory.mkdirs()) {
                        result.error("cache_unavailable", null, null)
                    } else {
                        result.success(updateFile().absolutePath)
                    }
                }
                "install" -> {
                    val build = call.argument<Int>("buildNumber")
                    val file = updateFile()
                    if (build == null || !runCatching { isExpectedUpdate(file, build) }.getOrDefault(false)) {
                        result.error("invalid_update", null, null)
                    } else {
                        activity.runOnUiThread { openInstaller(file, result) }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun updateDirectory() = File(activity.cacheDir, "field-updates")

    private fun updateFile() = File(updateDirectory(), "ploggr-field.apk")

    @Suppress("DEPRECATION")
    private fun isExpectedUpdate(file: File, build: Int): Boolean {
        val manager = activity.packageManager
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            PackageManager.GET_SIGNATURES
        }
        val archive = manager.getPackageArchiveInfo(file.absolutePath, flags) ?: return false
        if (archive.packageName != activity.packageName ||
            PackageInfoCompat.getLongVersionCode(archive) != build.toLong()) return false
        val installed = manager.getPackageInfo(activity.packageName, flags)
        val archiveSigners = signers(archive)
        return build > PackageInfoCompat.getLongVersionCode(installed) &&
            archiveSigners.isNotEmpty() && archiveSigners == signers(installed)
    }

    @Suppress("DEPRECATION")
    private fun signers(info: PackageInfo): Set<Signature> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.apkContentsSigners.orEmpty().toSet()
        } else {
            info.signatures.orEmpty().toSet()
        }

    private fun openInstaller(file: File, result: MethodChannel.Result) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                !activity.packageManager.canRequestPackageInstalls()) {
                activity.startActivity(
                    Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}")),
                )
                result.success("permissionRequired")
                return
            }
            val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.field-updates", file)
            activity.startActivity(Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            })
            result.success("installerOpened")
        } catch (_: RuntimeException) {
            result.error("installer_unavailable", null, null)
        }
    }
}
