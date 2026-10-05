import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;

import '../config/api_config.dart';
import '../models/attendance_log.dart';
import '../models/event.dart';
import '../models/fine.dart';
import '../models/qr_slot.dart';
import '../models/student_profile.dart';
import '../models/user.dart';
import '../utils/image_type.dart';
import 'token_storage.dart';

/// Raised for non-2xx responses; carries the parsed body so callers can read
/// the backend's `detail`/`code` fields.
class ApiException implements Exception {
  final int statusCode;
  final String message;
  final dynamic data;
  ApiException(this.statusCode, this.message, [this.data]);

  /// Backend error code (e.g. STALE_QR) when present.
  String? get code => data is Map ? data['code'] as String? : null;

  @override
  String toString() => message;
}

/// Raised when the session can't be recovered (refresh failed) — the app
/// should bounce the user back to the login screen.
class SessionExpired implements Exception {}

/// Central authenticated HTTP client.
///
/// Attaches the JWT access token to every request and transparently refreshes
/// it once on a 401; if the refresh also fails, it clears the tokens, notifies
/// [onUnauthorized] and throws [SessionExpired].
class ApiService {
  final TokenStorage _tokens;
  final http.Client _client;

  /// Called when the session is irrecoverably expired (drives logout/redirect).
  void Function()? onUnauthorized;

  ApiService({TokenStorage? tokens, http.Client? client})
      : _tokens = tokens ?? TokenStorage(),
        _client = client ?? http.Client();

  TokenStorage get tokens => _tokens;
  Future<bool> get hasToken => _tokens.hasTokens;

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final q = query?.map((k, v) => MapEntry(k, '$v'));
    return Uri.parse('${ApiConfig.apiBase}$path')
        .replace(queryParameters: (q != null && q.isNotEmpty) ? q : null);
  }

  // -------------------------------------------------------------------------
  // Auth
  // -------------------------------------------------------------------------
  /// Obtain and store tokens. Throws [ApiException] on bad credentials.
  Future<void> login(String username, String password) async {
    final res = await _client.post(
      _uri('/auth/login/'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'username': username, 'password': password}),
    );
    if (res.statusCode == 200) {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      await _tokens.save(
        access: body['access'] as String,
        refresh: body['refresh'] as String,
      );
      return;
    }
    throw _exceptionFrom(res, fallback: 'Invalid username or password.');
  }

  Future<User> fetchMe() async {
    final data = await getJson('/me/') as Map<String, dynamic>;
    return User.fromJson(data);
  }

  Future<void> logout() => _tokens.clear();

  // -------------------------------------------------------------------------
  // Domain endpoints (typed)
  // -------------------------------------------------------------------------
  /// DRF list endpoints are paginated (`{count, results}`); unwrap to a list.
  List<dynamic> _results(dynamic data) {
    if (data is Map && data['results'] is List) return data['results'] as List;
    if (data is List) return data;
    return const [];
  }

  /// Fetch every page of a paginated list endpoint (follows `next`).
  ///
  /// Only the `page` number is taken from `next` and re-sent against our own
  /// base URL — the absolute URL the server builds can carry a different
  /// scheme/host when it sits behind a proxy.
  Future<List<dynamic>> _getAll(String path,
      {Map<String, dynamic>? query}) async {
    final out = <dynamic>[];
    var page = 1;
    // The page cap is a safety net against a server that never ends `next`.
    for (var i = 0; i < 100; i++) {
      final data = await getJson(path, query: {
        ...?query,
        if (page > 1) 'page': page,
      });
      out.addAll(_results(data));
      final next = data is Map ? data['next'] as String? : null;
      if (next == null || next.isEmpty) break;
      final nextPage =
          int.tryParse(Uri.parse(next).queryParameters['page'] ?? '');
      if (nextPage == null || nextPage <= page) break;
      page = nextPage;
    }
    return out;
  }

  // --- Instructor ---
  Future<List<Event>> instructorEvents() async {
    final data = await getJson('/instructor/events/');
    return _results(data)
        .map((e) => Event.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Submit a scanned token. Never throws for the documented failure cases —
  /// returns a [ScanResult] carrying the backend's message/code instead.
  Future<ScanResult> scan(String token) async {
    try {
      final res = await post('/instructor/scan/', body: {'token': token});
      return ScanResult.success(
        res.data as Map<String, dynamic>,
        created: res.status == 201,
      );
    } on ApiException catch (e) {
      return ScanResult.failure(e.message, e.code);
    }
  }

  Future<List<AttendanceLog>> instructorScans({int? event, String? date}) async {
    final data = await getJson('/instructor/scans/', query: {
      'event': ?event,
      'date': ?date,
    });
    return _results(data)
        .map((e) => AttendanceLog.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // --- Student ---
  Future<StudentProfile> studentProfile() async {
    final data = await getJson('/student/profile/') as Map<String, dynamic>;
    return StudentProfile.fromJson(data);
  }

  Future<Balance> studentBalance() async {
    final data = await getJson('/student/balance/') as Map<String, dynamic>;
    return Balance.fromJson(data);
  }

  /// Current + upcoming ACTIVE events.
  Future<List<Event>> studentEvents() async {
    final data = await _getAll('/student/events/');
    return data.map((e) => Event.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// ALL events (past, current, future), newest start date first.
  Future<List<Event>> studentEventsAll() async {
    final data = await _getAll('/student/events/', query: {'all': 'true'});
    return data.map((e) => Event.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<QrSlot> generateQr({
    required int event,
    required String date,
  }) async {
    final res = await post('/student/qr/generate/', body: {
      'event': event,
      'date': date,
    });
    return QrSlot.fromJson(res.data as Map<String, dynamic>);
  }

  Future<List<QrSlot>> studentQrs({int? event, String? date}) async {
    final data = await getJson('/student/qr/', query: {
      'event': ?event,
      'date': ?date,
    });
    return _results(data)
        .map((e) => QrSlot.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// The student's attendance logs (all pages); omit [event] for every event.
  Future<List<AttendanceLog>> studentAttendance({int? event}) async {
    final data = await _getAll('/student/attendance/', query: {
      'event': ?event,
    });
    return data
        .map((e) => AttendanceLog.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<Fine>> studentFines() async {
    final data = await _getAll('/student/fines/');
    return data.map((e) => Fine.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Edit the student's own profile. [fields] holds only the changed keys of
  /// `first_name`, `middle_name`, `last_name`, `username`, `email`. Field
  /// errors arrive as an [ApiException] whose `data` is `{field: [msgs]}`.
  Future<StudentProfile> updateProfile(Map<String, String> fields) async {
    final res = await _send('PATCH', '/student/profile/', body: fields);
    return StudentProfile.fromJson(_decode(res) as Map<String, dynamic>);
  }

  /// Change the password (204 on success). A wrong current password or a weak
  /// new one raises an [ApiException] with `current_password` / `new_password`.
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    await post('/student/profile/password/', body: {
      'current_password': currentPassword,
      'new_password': newPassword,
    });
  }

  /// Upload a new profile photo (multipart field `image`); returns its URL.
  Future<String?> uploadPhoto(Uint8List bytes, ImageType type) async {
    final res = await _sendMultipart('/me/photo/', () {
      return http.MultipartFile.fromBytes(
        'image',
        bytes,
        filename: 'profile.${type.extension}',
        contentType: MediaType.parse(type.mime),
      );
    });
    final data = _decode(res);
    return data is Map ? data['profile_image'] as String? : null;
  }

  /// Remove the profile photo (204).
  Future<void> deletePhoto() async {
    _decode(await _send('DELETE', '/me/photo/'));
  }

  /// Try to mint a new access token from the stored refresh token.
  Future<bool> _refresh() async {
    final refresh = await _tokens.refresh;
    if (refresh == null) return false;
    final res = await _client.post(
      _uri('/auth/refresh/'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'refresh': refresh}),
    );
    if (res.statusCode == 200) {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      // The server rotates refresh tokens and blacklists the old one, so the
      // new refresh token must replace the stored one or the next refresh fails.
      final newRefresh = body['refresh'] as String?;
      if (newRefresh != null) {
        await _tokens.save(
          access: body['access'] as String,
          refresh: newRefresh,
        );
      } else {
        await _tokens.saveAccess(body['access'] as String);
      }
      return true;
    }
    return false;
  }

  // -------------------------------------------------------------------------
  // Core request (with one transparent refresh-and-retry on 401)
  // -------------------------------------------------------------------------
  /// Runs [attempt] with the current access token; on a 401 refreshes the
  /// token once and retries. If it still fails the session is over: clear the
  /// tokens, notify [onUnauthorized] and throw [SessionExpired]. Shared by the
  /// JSON and multipart paths so both follow one refresh policy.
  Future<http.Response> _withAuth(
    Future<http.Response> Function(String? token) attempt,
  ) async {
    var res = await attempt(await _tokens.access);
    if (res.statusCode == 401) {
      final refreshed = await _refresh();
      if (refreshed) {
        res = await attempt(await _tokens.access);
      }
      if (res.statusCode == 401) {
        await _tokens.clear();
        onUnauthorized?.call();
        throw SessionExpired();
      }
    }
    return res;
  }

  Future<http.Response> _send(
    String method,
    String path, {
    Map<String, dynamic>? query,
    Object? body,
  }) {
    return _withAuth((token) {
      final headers = <String, String>{
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };
      final uri = _uri(path, query);
      final encoded = body != null ? jsonEncode(body) : null;
      switch (method) {
        case 'GET':
          return _client.get(uri, headers: headers);
        case 'POST':
          return _client.post(uri, headers: headers, body: encoded);
        case 'PATCH':
          return _client.patch(uri, headers: headers, body: encoded);
        case 'DELETE':
          return _client.delete(uri, headers: headers);
        default:
          throw UnsupportedError('Unsupported method: $method');
      }
    });
  }

  /// POST a multipart form with one file. [file] is a factory because a
  /// [http.MultipartRequest] can be sent only once — the 401 retry needs a
  /// fresh request (and a fresh file stream).
  Future<http.Response> _sendMultipart(
    String path,
    http.MultipartFile Function() file,
  ) {
    return _withAuth((token) async {
      final req = http.MultipartRequest('POST', _uri(path));
      if (token != null) req.headers['Authorization'] = 'Bearer $token';
      req.files.add(file());
      return http.Response.fromStream(await _client.send(req));
    });
  }

  // -------------------------------------------------------------------------
  // JSON helpers
  // -------------------------------------------------------------------------
  Future<dynamic> getJson(String path, {Map<String, dynamic>? query}) async {
    final res = await _send('GET', path, query: query);
    return _decode(res);
  }

  /// POST returning the decoded body plus the status code (some endpoints use
  /// 200 vs 201 semantically — e.g. scan "already recorded" vs "recorded").
  Future<({int status, dynamic data})> post(String path, {Object? body}) async {
    final res = await _send('POST', path, body: body);
    return (status: res.statusCode, data: _decode(res));
  }

  dynamic _decode(http.Response res) {
    final ok = res.statusCode >= 200 && res.statusCode < 300;
    final parsed = res.body.isNotEmpty ? jsonDecode(res.body) : null;
    if (ok) return parsed;
    throw ApiException(res.statusCode, _messageFrom(parsed), parsed);
  }

  ApiException _exceptionFrom(http.Response res, {required String fallback}) {
    final parsed = res.body.isNotEmpty ? jsonDecode(res.body) : null;
    return ApiException(res.statusCode, _messageFrom(parsed, fallback), parsed);
  }

  String _messageFrom(dynamic parsed, [String fallback = 'Request failed.']) {
    if (parsed is Map) {
      if (parsed['detail'] != null) return '${parsed['detail']}';
      // Surface the first field error if present.
      for (final v in parsed.values) {
        if (v is List && v.isNotEmpty) return '${v.first}';
        if (v is String) return v;
      }
    }
    return fallback;
  }

  void dispose() => _client.close();
}
