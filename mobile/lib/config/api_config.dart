/// Central API configuration.
///
/// The backend address is a **build-time** value supplied with
/// `--dart-define=API_BASE_URL=...`, so the same source builds for a dev machine
/// or the deployed server without editing code. With no define the dev default
/// below is used, so a plain `flutter run` keeps working.
///
///   * Dev on the LAN (emulator or device on the same Wi-Fi):
///       flutter run --dart-define=API_BASE_URL=http://192.168.1.10:8000
///   * Android emulator -> host loopback:  http://10.0.2.2:8000
///   * iOS simulator:                      http://127.0.0.1:8000
///   * Release APK against the deployed backend (origin only: no `/api`):
///       flutter build apk --release --dart-define=API_BASE_URL=https://attendance.example.com
///
/// See DEPLOYMENT.md ("Flutter release APK") for the full procedure.
class ApiConfig {
  static const String _rawBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://192.168.1.9:8080',
  );

  /// Backend origin, normalised so a trailing `/` can't produce `//api`.
  static final String baseUrl = _rawBaseUrl.endsWith('/')
      ? _rawBaseUrl.substring(0, _rawBaseUrl.length - 1)
      : _rawBaseUrl;

  /// Root of the REST API.
  static String get apiBase => '$baseUrl/api';
}
