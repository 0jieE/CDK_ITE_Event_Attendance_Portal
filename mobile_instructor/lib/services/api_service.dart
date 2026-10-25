import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../models/attendance_log.dart';
import '../models/event.dart';
import '../models/event_attendance.dart';
import '../models/offline_pack.dart';
import '../models/scan_result.dart';
import '../models/user.dart';
import '../utils/errors.dart' show isNetworkError;
import '../utils/manila_time.dart' show apiDate;
import 'local_cache.dart';
import 'token_storage.dart';

/// Raised for non-2xx responses; carries the parsed body so callers can read
/// the backend's `detail`/`code` fields.
class ApiException implements Exception {
  final int statusCode;
  final String message;
  final dynamic data;
  ApiException(this.statusCode, this.message, [this.data]);

  /// Backend machine code (e.g. STALE_QR) when present.
  String? get code {
    final c = data is Map ? data['code'] : null;
    return c is String ? c : null;
  }

  @override
  String toString() => message;
}

/// Raised when the session can't be recovered (refresh failed) — the app
/// should bounce the user back to the login screen.
class SessionExpired implements Exception {}

/// Offline, and nothing for this request was saved on this phone yet.
class OfflineDataMissing implements Exception {
  final String message;
  const OfflineDataMissing([
    this.message = "You're offline and this hasn't been saved on this phone "
        'yet. Open the app once with internet so it can download it.',
  ]);

  @override
  String toString() => message;
}

/// Central authenticated HTTP client.
///
/// Attaches the JWT access token to every request and transparently refreshes
/// it once on a 401; if the refresh also fails, it clears the tokens, notifies
/// [onUnauthorized] and throws [SessionExpired].
class ApiService {
  final TokenStorage _tokens;
  final http.Client _client;

  /// On-phone store for what the app shows while offline.
  final LocalCache cache;

  /// Called when the session is irrecoverably expired (drives logout/redirect).
  void Function()? onUnauthorized;

  /// Whose data the read cache holds: the signed-in user's id (set by the
  /// auth provider). Null turns the cache off.
  int? cacheOwner;

  /// Reachability reports from requests, and whether the phone is already
  /// known to be offline (then reads skip the network). Wired to the
  /// connectivity service.
  void Function()? onReachable;
  void Function()? onUnreachable;
  bool Function()? isKnownOffline;

  /// While screens show saved data: when the oldest of it was downloaded
  /// (null while everything shown is live).
  final ValueNotifier<DateTime?> offlineDataTime = ValueNotifier(null);

  ApiService({TokenStorage? tokens, http.Client? client, LocalCache? cache})
      : _tokens = tokens ?? TokenStorage(),
        _client = client ?? http.Client(),
        cache = cache ?? const LocalCache();

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
    final error = _exceptionFrom(res, fallback: 'Invalid username or password.');
    // Wrong credentials: always our own wording rather than the server's
    // "No active account found...".
    if (res.statusCode == 401) {
      throw ApiException(401, 'Invalid username or password.', error.data);
    }
    throw error;
  }

  Future<User> fetchMe() async {
    final data = await getJson('/me/') as Map<String, dynamic>;
    return User.fromJson(data);
  }

  Future<void> logout() => _tokens.clear();

  /// Can the server be reached at all? (Any HTTP answer counts; no auth.)
  Future<bool> ping() async {
    try {
      await _client
          .get(Uri.parse('${ApiConfig.baseUrl}/healthz/'))
          .timeout(const Duration(seconds: 8));
      return true;
    } catch (_) {
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // Read cache (offline)
  // -------------------------------------------------------------------------
  /// Per user and per request (path + sorted query), e.g.
  /// `cache:7:/instructor/events/3/attendance/?date=2026-10-08`.
  String? _cacheKey(String path, Map<String, dynamic>? query) {
    final owner = cacheOwner;
    if (owner == null) return null;
    final q = [
      for (final e in (query ?? const <String, dynamic>{}).entries)
        if (e.value != null) '${e.key}=${e.value}',
    ]..sort();
    return 'cache:$owner:$path${q.isEmpty ? '' : '?${q.join('&')}'}';
  }

  /// Read-through cache for the screens' GETs: fresh from the server when it
  /// can be reached (and saved on the phone), otherwise the saved copy - and
  /// when the phone is known to be offline the network isn't tried at all.
  /// With nothing saved, throws [OfflineDataMissing] (never an empty list).
  Future<dynamic> _cached(
    String path,
    Map<String, dynamic>? query,
    Future<dynamic> Function() fetch,
  ) async {
    final key = _cacheKey(path, query);
    if (key == null) return fetch();
    if (isKnownOffline?.call() ?? false) return _fromCache(key);
    try {
      // With a saved copy to fall back on, don't hang on a dead network.
      final hasCopy = await cache.read(key) != null;
      final data = await (hasCopy
          ? fetch().timeout(const Duration(seconds: 15))
          : fetch());
      onReachable?.call();
      offlineDataTime.value = null;
      await cache.writeJson(key, {
        'at': DateTime.now().toUtc().toIso8601String(),
        'data': data,
      });
      return data;
    } catch (e) {
      if (!isNetworkError(e)) rethrow;
      onUnreachable?.call();
      return _fromCache(key);
    }
  }

  Future<dynamic> _fromCache(String key) async {
    final stored = await cache.readJson(key);
    if (stored is! Map || !stored.containsKey('data')) {
      throw const OfflineDataMissing();
    }
    final at = DateTime.tryParse('${stored['at']}');
    final shown = offlineDataTime.value;
    if (at != null && (shown == null || at.isBefore(shown))) {
      offlineDataTime.value = at;
    }
    return stored['data'];
  }

  Future<dynamic> _cachedGet(String path, [Map<String, dynamic>? query]) =>
      _cached(path, query, () => getJson(path, query: query));

  Future<List<dynamic>> _cachedAll(String path,
          [Map<String, dynamic>? query]) async =>
      (await _cached(path, query, () => _getAll(path, query: query))) as List;

  /// Forget everything cached for [owner] (offline sign-in turned off).
  Future<void> clearCacheFor(int owner) =>
      cache.removeWhere((k) => k.startsWith('cache:$owner:'));

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
    final data = await _cachedGet('/instructor/events/');
    return _results(data)
        .map((e) => Event.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// ALL events (finished, running, upcoming), newest start date first —
  /// instructors only. (Without `all=true` the endpoint lists just today's
  /// scannable events, see [instructorEvents].)
  Future<List<Event>> instructorEventsAll() async {
    final data = await _cachedAll('/instructor/events/', {'all': 'true'});
    return data.map((e) => Event.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// The class roster for one event-day. Omit [date] to let the server pick
  /// (today if the event runs today, else its last/first day). A bad or
  /// out-of-range date is a 400 [ApiException]; an unknown event is a 404.
  Future<EventAttendance> instructorEventAttendance(
    int eventId, {
    DateTime? date,
  }) async {
    final data = await _cachedGet(
      '/instructor/events/$eventId/attendance/',
      {if (date != null) 'date': apiDate(date)},
    );
    return EventAttendance.fromJson(data as Map<String, dynamic>);
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

  /// Today's events + today's student QR codes (hashed) for scanning offline.
  /// [receivedAt] (default: now) is the phone time the reply arrived, used to
  /// measure the phone's clock error.
  Future<OfflinePack> instructorOfflinePack({DateTime? receivedAt}) async {
    final data = await getJson('/instructor/offline-pack/');
    return OfflinePack.fromJson(
        data as Map<String, dynamic>, receivedAt ?? DateTime.now());
  }

  /// Upload scans queued offline. One result map per scan, in order: the live
  /// scan body plus `http_status` (201 recorded, 200 already, else rejected).
  Future<List<Map<String, dynamic>>> syncScans(List<QueuedScan> scans) async {
    final res = await post('/instructor/scans/sync/', body: {
      'scans': [
        for (final s in scans)
          {'token': s.token, 'scanned_at': s.scannedAt.toUtc().toIso8601String()},
      ],
    });
    final results = (res.data as Map<String, dynamic>)['results'] as List;
    return results.cast<Map<String, dynamic>>();
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
  /// tokens, notify [onUnauthorized] and throw [SessionExpired].
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
        default:
          throw UnsupportedError('Unsupported method: $method');
      }
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
    if (ok) return res.body.isNotEmpty ? jsonDecode(res.body) : null;
    // Error bodies are often NOT JSON (a proxy's or Django's HTML error page); decode
    // leniently so they become a proper ApiException, not a FormatException that the UI
    // would show as "could not reach the server".
    final parsed = _tryDecode(res.body);
    throw ApiException(res.statusCode, _messageFrom(parsed, _fallbackFor(res.statusCode)), parsed);
  }

  /// Message for an error response that carried no readable `detail`.
  String _fallbackFor(int status) {
    if (status == 404) return "This feature isn't available on the server yet.";
    if (status >= 500) return 'The server had a problem. Please try again in a moment.';
    return 'Request failed.';
  }

  ApiException _exceptionFrom(http.Response res, {required String fallback}) {
    final parsed = _tryDecode(res.body);
    return ApiException(res.statusCode, _messageFrom(parsed, fallback), parsed);
  }

  /// Decoded JSON, or null when the body is empty / not JSON (e.g. a proxy's
  /// HTML error page).
  dynamic _tryDecode(String body) {
    if (body.isEmpty) return null;
    try {
      return jsonDecode(body);
    } on FormatException {
      return null;
    }
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
