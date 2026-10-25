import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Small key/value store on the phone for what the app needs while offline:
/// the signed-in user, saved screens, the offline pack and the queued scans.
///
/// It never throws. Storage trouble (or no plugin at all, as in widget tests)
/// just means "nothing cached", so it can't break a screen that only wanted a
/// fallback.
class LocalCache {
  const LocalCache();

  Future<String?> read(String key) async {
    try {
      return (await SharedPreferences.getInstance()).getString(key);
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String key, String value) async {
    try {
      await (await SharedPreferences.getInstance()).setString(key, value);
    } catch (_) {/* best effort */}
  }

  Future<void> remove(String key) async {
    try {
      await (await SharedPreferences.getInstance()).remove(key);
    } catch (_) {/* best effort */}
  }

  /// Remove every key matching [test].
  Future<void> removeWhere(bool Function(String key) test) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final k in prefs.getKeys().where(test).toList()) {
        await prefs.remove(k);
      }
    } catch (_) {/* best effort */}
  }

  /// Decoded JSON stored under [key], or null (missing or unreadable).
  Future<dynamic> readJson(String key) async {
    final raw = await read(key);
    if (raw == null) return null;
    try {
      return jsonDecode(raw);
    } on FormatException {
      return null;
    }
  }

  Future<void> writeJson(String key, Object? value) =>
      write(key, jsonEncode(value));
}
