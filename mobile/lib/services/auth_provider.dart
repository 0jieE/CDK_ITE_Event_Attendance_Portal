import 'package:flutter/foundation.dart';

import '../models/student_profile.dart';
import '../models/user.dart';
import '../utils/errors.dart';
import 'api_service.dart';

enum AuthStatus { unknown, unauthenticated, authenticated }

/// Single source of truth for auth state. Owns the [ApiService] and reacts to
/// irrecoverable session expiry by dropping back to the unauthenticated state.
class AuthProvider extends ChangeNotifier {
  final ApiService api;

  AuthStatus _status = AuthStatus.unknown;
  User? _user;
  String? _error;
  bool _busy = false;

  AuthProvider({ApiService? apiService}) : api = apiService ?? ApiService() {
    api.onUnauthorized = _handleSessionExpired;
  }

  AuthStatus get status => _status;
  User? get user => _user;
  String? get error => _error;
  bool get busy => _busy;

  static const _kUser = 'auth:user';

  /// On launch: if we have a token, validate it via /me/; else go to login.
  /// With no connection the last signed-in user is used, so the app still
  /// opens offline (the server re-checks the session on the next request).
  Future<void> bootstrap() async {
    if (!await api.hasToken) {
      _set(status: AuthStatus.unauthenticated);
      return;
    }
    try {
      _user = await api.fetchMe();
      await _cacheUser();
      _set(status: AuthStatus.authenticated);
    } catch (e) {
      final cached = isNetworkError(e) ? await _cachedUser() : null;
      if (cached != null) {
        _user = cached;
        _set(status: AuthStatus.authenticated);
        return;
      }
      // Offline with nothing cached: keep the tokens, just ask to sign in.
      if (!isNetworkError(e)) await api.logout();
      _set(status: AuthStatus.unauthenticated);
    }
  }

  Future<void> _cacheUser() async {
    final user = _user;
    if (user != null) await api.cache.writeJson(_kUser, user.toJson());
  }

  Future<User?> _cachedUser() async {
    final json = await api.cache.readJson(_kUser);
    if (json is! Map) return null;
    try {
      return User.fromJson(Map<String, dynamic>.from(json));
    } catch (_) {
      return null;
    }
  }

  Future<bool> login(String username, String password) async {
    _set(busy: true, error: null);
    try {
      await api.login(username.trim(), password);
      _user = await api.fetchMe();
      await _cacheUser();
      _set(status: AuthStatus.authenticated, busy: false);
      return true;
    } on ApiException catch (e) {
      _set(busy: false, error: e.message);
      return false;
    } catch (_) {
      _set(busy: false, error: 'Could not reach the server. Check your connection.');
      return false;
    }
  }

  /// Hide the last login failure (e.g. when leaving the login screen).
  void clearError() {
    if (_error == null) return;
    _set(error: null);
  }

  Future<void> logout() async {
    await api.logout();
    await api.cache.remove(_kUser);
    _user = null;
    _set(status: AuthStatus.unauthenticated, error: null);
  }

  /// Mirror an edited profile into the cached user so every header/avatar that
  /// watches [user] shows the new name, username and photo at once.
  void applyProfile(StudentProfile profile) {
    final current = _user;
    if (current == null) return;
    _user = current.copyWith(
      username: profile.username.isNotEmpty ? profile.username : null,
      fullName: profile.fullName.isNotEmpty ? profile.fullName : null,
      profileImage: profile.profileImage,
      clearPhoto: profile.profileImage == null,
    );
    _cacheUser();
    notifyListeners();
  }

  /// Update just the cached photo URL (null = removed).
  void setPhoto(String? url) {
    final current = _user;
    if (current == null) return;
    _user = current.copyWith(profileImage: url, clearPhoto: url == null);
    _cacheUser();
    notifyListeners();
  }

  void _handleSessionExpired() {
    _user = null;
    api.cache.remove(_kUser);
    _set(status: AuthStatus.unauthenticated);
  }

  void _set({AuthStatus? status, bool? busy, Object? error = _sentinel}) {
    if (status != null) _status = status;
    if (busy != null) _busy = busy;
    if (!identical(error, _sentinel)) _error = error as String?;
    notifyListeners();
  }

  static const _sentinel = Object();
}
