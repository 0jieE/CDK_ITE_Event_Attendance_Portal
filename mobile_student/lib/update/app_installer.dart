import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// The installed app's version, as Android reports it.
class InstalledApp {
  final String versionName; // "1.0.0"
  final int versionCode; // the "+N" build number
  const InstalledApp(this.versionName, this.versionCode);
}

/// Android side of updating (MainActivity.kt, channel `ph.edu.cok/app_update`):
/// the installed version, the folder downloads go to, the "install unknown
/// apps" permission, and handing an APK to Android's own installer through a
/// FileProvider. Android always asks the user to confirm - nothing is
/// installed silently.
class AppInstaller {
  static const _channel = MethodChannel('ph.edu.cok/app_update');

  const AppInstaller();

  /// Updates via APK are an Android feature.
  bool get supported => !kIsWeb && Platform.isAndroid;

  Future<InstalledApp> installedApp() async {
    final info = await _channel.invokeMapMethod<String, dynamic>('appInfo');
    return InstalledApp(
      '${info?['versionName'] ?? ''}',
      (info?['versionCode'] as num?)?.toInt() ?? 0,
    );
  }

  /// A private cache folder for downloaded APKs (shared with the installer
  /// only through the FileProvider).
  Future<String> updateDir() async =>
      (await _channel.invokeMethod<String>('updateDir'))!;

  /// May this app hand APKs to the installer? (Android 8+: the user's
  /// "Install unknown apps" setting for this app.)
  Future<bool> canInstallPackages() async =>
      await _channel.invokeMethod<bool>('canInstallPackages') ?? false;

  /// Opens this app's "Install unknown apps" setting.
  Future<void> openInstallSettings() =>
      _channel.invokeMethod<void>('openInstallSettings');

  /// Opens Android's installer for the APK at [path].
  Future<void> installApk(String path) =>
      _channel.invokeMethod<void>('installApk', {'path': path});
}
