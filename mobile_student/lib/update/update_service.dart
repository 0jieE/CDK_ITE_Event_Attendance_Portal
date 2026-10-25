import 'package:flutter/foundation.dart';

import '../config/update_config.dart';
import 'apk_downloader.dart';
import 'app_installer.dart';
import 'app_version.dart';
import 'github_releases.dart';

enum UpdateStatus { idle, checking, upToDate, available, failed }

/// Finds out whether a newer release of this app is on GitHub.
///
/// Automatic checks (start-up, back to the foreground) run at most every
/// [UpdateConfig.autoCheckInterval] and fail silently; a manual check always
/// runs and reports its outcome. An optional update the user dismissed with
/// "Later" isn't offered again in the same session. Only a strictly higher
/// version counts, so a downgrade is never offered.
class UpdateService extends ChangeNotifier {
  final GitHubReleaseClient releases;
  final AppInstaller installer;
  final ApkDownloader downloader;
  final DateTime Function() _clock;
  final Duration autoInterval;

  UpdateService({
    GitHubReleaseClient? releases,
    this.installer = const AppInstaller(),
    ApkDownloader? downloader,
    DateTime Function()? clock,
    this.autoInterval = UpdateConfig.autoCheckInterval,
  })  : releases = releases ?? GitHubReleaseClient(),
        downloader = downloader ?? ApkDownloader(),
        _clock = clock ?? DateTime.now;

  UpdateStatus _status = UpdateStatus.idle;
  InstalledApp? _installed;
  AppRelease? _latest;
  String? _error;
  DateTime? _lastCheck;
  final _dismissed = <String>{};

  UpdateStatus get status => _status;
  InstalledApp? get installed => _installed;

  /// The newer release, while [status] is [UpdateStatus.available].
  AppRelease? get available =>
      _status == UpdateStatus.available ? _latest : null;

  /// Why the last check failed (for a manual check's message).
  String? get error => _error;

  /// An update the user hasn't dismissed this session: time to offer it.
  bool get shouldPrompt {
    final r = available;
    return r != null && !_dismissed.contains(r.tag);
  }

  /// "Later": don't offer [release] again this session.
  void dismiss(AppRelease release) {
    _dismissed.add(release.tag);
    notifyListeners();
  }

  /// The installed version, read once (e.g. for "Version 1.0.0 (4)").
  Future<InstalledApp?> loadInstalled() async {
    if (_installed != null || !installer.supported) return _installed;
    try {
      _installed = await installer.installedApp();
      notifyListeners();
    } catch (_) {/* not fatal: the check reports it */}
    return _installed;
  }

  /// Check GitHub. Automatic checks are throttled; a [manual] one isn't.
  /// Never throws - the outcome is in [status] / [error].
  Future<UpdateStatus> check({bool manual = false}) async {
    if (_status == UpdateStatus.checking) return _status;
    if (!installer.supported) return _status;
    final now = _clock();
    final last = _lastCheck;
    if (!manual && last != null && now.difference(last) < autoInterval) {
      return _status;
    }
    _status = UpdateStatus.checking;
    _error = null;
    notifyListeners();
    _lastCheck = now;

    try {
      final installed = await loadInstalled();
      final current =
          installed == null ? null : AppVersion.tryParse(installed.versionName);
      if (current == null) {
        throw const UpdateCheckException(UpdateCheckFailure.badResponse,
            "This app's version couldn't be read.");
      }
      final latest = await releases.latestRelease();
      _latest = latest;
      _status = (latest != null && latest.version > current)
          ? UpdateStatus.available
          : UpdateStatus.upToDate;
    } on UpdateCheckException catch (e) {
      _status = UpdateStatus.failed;
      _error = e.message;
    } catch (_) {
      _status = UpdateStatus.failed;
      _error = "Couldn't check for updates. Try again later.";
    }
    notifyListeners();
    return _status;
  }
}
