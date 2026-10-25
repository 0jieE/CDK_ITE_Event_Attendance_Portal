package ph.edu.cok.ite_instructors

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * In-app updates (lib/update/app_installer.dart): reports the installed
 * version, gives the folder downloads go to, checks and opens the
 * "Install unknown apps" setting, and hands a downloaded APK to Android's own
 * package installer. The installer always asks the user to confirm.
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "appInfo" -> result.success(appInfo())
                        "updateDir" -> result.success(updateDir().absolutePath)
                        "canInstallPackages" -> result.success(canInstallPackages())
                        "openInstallSettings" -> {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startActivity(
                                    Intent(
                                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                        Uri.parse("package:$packageName"),
                                    )
                                )
                            }
                            result.success(null)
                        }
                        "installApk" -> {
                            installApk(File(call.argument<String>("path")!!))
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("UPDATE_ERROR", e.message, null)
                }
            }
    }

    private fun appInfo(): Map<String, Any?> {
        val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getPackageInfo(packageName, PackageManager.PackageInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            packageManager.getPackageInfo(packageName, 0)
        }
        val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
        return mapOf("versionName" to info.versionName, "versionCode" to code)
    }

    /** cache/updates - the only folder the update FileProvider shares. */
    private fun updateDir(): File = File(cacheDir, "updates").apply { mkdirs() }

    private fun canInstallPackages(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            packageManager.canRequestPackageInstalls()

    private fun installApk(apk: File) {
        // Only APKs this app downloaded into its own update folder.
        require(apk.canonicalPath.startsWith(updateDir().canonicalPath + File.separator)) {
            "Not an update download"
        }
        require(apk.isFile) { "The downloaded update is missing" }
        val uri = FileProvider.getUriForFile(this, "$packageName.updates", apk)
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
    }

    companion object {
        private const val CHANNEL = "ph.edu.cok/app_update"
    }
}

/** Shares downloaded update APKs with the system installer (its own class,
 * so it can't clash with a plugin's FileProvider in the merged manifest). */
class UpdateFileProvider : FileProvider()
