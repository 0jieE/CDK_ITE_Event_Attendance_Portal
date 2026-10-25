/// Where the app looks for its updates: **GitHub Releases** of a public
/// repository. Everything about the release contract lives here (see
/// AUTO_UPDATE_SETUP.md).
///
/// The student and instructor apps publish to the same repository, so each
/// app only considers releases whose tag starts with its own [tagPrefix]
/// (e.g. `students-v1.0.1`) and downloads the asset named exactly [apkAsset].
class UpdateConfig {
  /// GitHub owner (user or organisation) and repository.
  static const owner = '0jieE';
  static const repo = 'CDK_ITE_Event_Attendance_Portal';

  /// Release tags for this app: `<tagPrefix><x.y.z>`, e.g. `students-v1.0.1`.
  static const tagPrefix = 'students-v';

  /// The APK file attached to each release.
  static const apkAsset = 'ite-students.apk';

  /// Automatic checks (start-up, back to foreground) happen at most this
  /// often; "Check for updates" always checks.
  static const autoCheckInterval = Duration(hours: 6);
}
