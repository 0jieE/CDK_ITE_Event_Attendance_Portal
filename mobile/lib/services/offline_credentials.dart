import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/user.dart';
import 'password_hash.dart';

/// A tiny key/value interface over the platform's secure storage (Android
/// Keystore / iOS Keychain), so tests can swap in memory.
class SecureStore {
  final FlutterSecureStorage _storage;
  SecureStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  Future<String?> read(String key) => _storage.read(key: key);
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  Future<void> delete(String key) => _storage.delete(key: key);
}

enum OfflineLoginStatus { ok, unknownAccount, expired, wrongPassword, locked }

/// Outcome of an offline sign-in attempt.
class OfflineLoginResult {
  final OfflineLoginStatus status;
  final User? user;

  /// Wrong password: tries left before the first wait.
  final int attemptsLeft;

  /// Locked: how long until the next try is allowed.
  final Duration retryAfter;

  const OfflineLoginResult(
    this.status, {
    this.user,
    this.attemptsLeft = 0,
    this.retryAfter = Duration.zero,
  });

  /// What to tell the user (null on success).
  String? get message {
    switch (status) {
      case OfflineLoginStatus.ok:
        return null;
      case OfflineLoginStatus.unknownAccount:
        return "You're offline, and this account hasn't signed in on this "
            'phone before. Connect to the internet to sign in.';
      case OfflineLoginStatus.expired:
        return "You're offline, and it has been over "
            '${OfflineCredentials.validityDays} days since this account '
            'signed in online. Connect to the internet to sign in again.';
      case OfflineLoginStatus.wrongPassword:
        return attemptsLeft > 0
            ? 'Invalid username or password. $attemptsLeft '
                '${attemptsLeft == 1 ? 'try' : 'tries'} left before a short wait.'
            : 'Invalid username or password.';
      case OfflineLoginStatus.locked:
        return 'Too many wrong passwords. Try again in ${_wait(retryAfter)}.';
    }
  }

  static String _wait(Duration d) {
    final s = d.inSeconds + (d.inMilliseconds % 1000 > 0 ? 1 : 0);
    if (s < 60) return '$s second${s == 1 ? '' : 's'}';
    final m = (s / 60).ceil();
    return '$m minute${m == 1 ? '' : 's'}';
  }
}

/// Lets an account sign in with no connection on a phone where it has
/// signed in online before.
///
/// After each online sign-in the password is stored only as a salted
/// PBKDF2-SHA256 hash (random salt per account, [iterations] rounds), together
/// with the user's profile, in secure storage. Offline, the typed password is
/// checked against that hash. Wrong passwords are limited: after
/// [freeAttempts] the account waits 30 s, doubling with every further miss
/// (up to an hour). An offline sign-in is refused [validity] after the last
/// online one, so an account must reconnect regularly.
class OfflineCredentials {
  static const validityDays = 30;
  static const defaultIterations = 100000;
  static const freeAttempts = 5;
  static const _firstWait = Duration(seconds: 30);
  static const _maxWait = Duration(hours: 1);

  final SecureStore _store;
  final int iterations;
  final Duration validity;
  final DateTime Function() _clock;

  /// Hash in a background isolate (keeps the UI smooth); tests turn it off.
  final bool useIsolate;

  OfflineCredentials({
    SecureStore? store,
    this.iterations = defaultIterations,
    this.validity = const Duration(days: validityDays),
    DateTime Function()? clock,
    this.useIsolate = true,
  })  : _store = store ?? SecureStore(),
        _clock = clock ?? DateTime.now;

  /// Storage key for an account (the username itself isn't used as a key).
  static String _key(String username) =>
      'offline_login:${sha256.convert(utf8.encode(username.trim()))}';

  /// After a successful **online** sign-in: remember [password] (hashed) and
  /// [user] for offline sign-in, and restart the [validity] period.
  Future<void> remember(String username, String password, User user) async {
    final salt = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final hash = await _hash(password, salt, iterations);
    await _write(username, {
      'user': user.toJson(),
      'salt': base64Encode(salt),
      'hash': base64Encode(hash),
      'iterations': iterations,
      'online_at': _clock().toUtc().toIso8601String(),
      'failures': 0,
    });
  }

  /// Keep the stored profile current (e.g. after the server re-confirmed the
  /// session) without touching the password or the validity period.
  Future<void> updateUser(String username, User user) async {
    final record = await _read(username);
    if (record == null) return;
    record['user'] = user.toJson();
    await _write(username, record);
  }

  /// The profile stored for [username], if any.
  Future<User?> storedUser(String username) async {
    final record = await _read(username);
    final user = record?['user'];
    if (user is! Map) return null;
    try {
      return User.fromJson(Map<String, dynamic>.from(user));
    } catch (_) {
      return null;
    }
  }

  Future<bool> has(String username) async => await _read(username) != null;

  Future<void> forget(String username) => _store.delete(_key(username));

  /// Forget [username] only if [password] is the one stored - used when the
  /// server refuses it online (changed password or disabled account), while a
  /// mere typo leaves offline sign-in working.
  Future<void> forgetIfMatches(String username, String password) async {
    final record = await _read(username);
    if (record != null && await _matches(record, password)) {
      await forget(username);
    }
  }

  /// Offline sign-in.
  Future<OfflineLoginResult> verify(String username, String password) async {
    final record = await _read(username);
    if (record == null) {
      return const OfflineLoginResult(OfflineLoginStatus.unknownAccount);
    }
    final now = _clock();
    final onlineAt = DateTime.tryParse('${record['online_at']}');
    if (onlineAt == null || now.difference(onlineAt) > validity) {
      await forget(username);
      return const OfflineLoginResult(OfflineLoginStatus.expired);
    }
    final lockedUntil = DateTime.tryParse('${record['locked_until']}');
    if (lockedUntil != null && now.isBefore(lockedUntil)) {
      return OfflineLoginResult(OfflineLoginStatus.locked,
          retryAfter: lockedUntil.difference(now));
    }

    if (await _matches(record, password)) {
      record['failures'] = 0;
      record.remove('locked_until');
      await _write(username, record);
      final user = await storedUser(username);
      if (user == null) {
        return const OfflineLoginResult(OfflineLoginStatus.unknownAccount);
      }
      return OfflineLoginResult(OfflineLoginStatus.ok, user: user);
    }

    final failures = ((record['failures'] as num?) ?? 0).toInt() + 1;
    record['failures'] = failures;
    if (failures >= freeAttempts) {
      final factor = 1 << (failures - freeAttempts).clamp(0, 20);
      var wait = _firstWait * factor;
      if (wait > _maxWait) wait = _maxWait;
      record['locked_until'] = now.add(wait).toUtc().toIso8601String();
      await _write(username, record);
      return OfflineLoginResult(OfflineLoginStatus.locked, retryAfter: wait);
    }
    await _write(username, record);
    return OfflineLoginResult(OfflineLoginStatus.wrongPassword,
        attemptsLeft: freeAttempts - failures);
  }

  // -------------------------------------------------------------------------
  Future<bool> _matches(Map<String, dynamic> record, String password) async {
    try {
      final salt = base64Decode(record['salt'] as String);
      final stored = base64Decode(record['hash'] as String);
      final rounds = (record['iterations'] as num).toInt();
      return constantTimeEquals(await _hash(password, salt, rounds), stored);
    } catch (_) {
      return false;
    }
  }

  Future<List<int>> _hash(String password, List<int> salt, int rounds) {
    final args = (utf8.encode(password), salt, rounds);
    return useIsolate
        ? compute(_pbkdf2, args)
        : Future.value(_pbkdf2(args));
  }

  static List<int> _pbkdf2((List<int>, List<int>, int) a) =>
      pbkdf2Sha256(a.$1, a.$2, a.$3, 32);

  Future<Map<String, dynamic>?> _read(String username) async {
    try {
      final raw = await _store.read(_key(username));
      if (raw == null) return null;
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(String username, Map<String, dynamic> record) =>
      _store.write(_key(username), jsonEncode(record));
}
