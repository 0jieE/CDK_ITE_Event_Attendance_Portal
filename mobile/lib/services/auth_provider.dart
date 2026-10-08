import 'package:flutter/foundation.dart';

import '../models/student_profile.dart';
import '../models/user.dart';
import 'api_service.dart';

enum AuthStatus { unknown, unauthenticated, authenticated }

/// Single source of truth for auth state. Owns the [ApiService] and reacts to
/// irrecoverable session expiry by dropping back to the unauthenticated state.
class AuthProvider extends ChangeNotifier {
  final ApiService api;

  AuthStatus _status = AuthStatus.unknown;
  User? _user;
  String? _error;
  String? _errorCode;
  bool _busy = false;

  AuthProvider({ApiService? apiService}) : api = apiService ?? ApiService() {
    api.onUnauthorized = _handleSessionExpired;
  }

  AuthStatus get status => _status;
  User? get user => _user;
  String? get error => _error;

  /// Backend machine code of the last login failure (e.g. PENDING_APPROVAL),
  /// so the login screen can style the message. Null for plain errors.
  String? get errorCode => _errorCode;
  bool get busy => _busy;

  /// On launch: if we have a token, validate it via /me/; else go to login.
  Future<void> bootstrap() async {
    if (!await api.hasToken) {
      _set(status: AuthStatus.unauthenticated);
      return;
    }
    try {
      _user = await api.fetchMe();
      _set(status: AuthStatus.authenticated);
    } catch (_) {
      await api.logout();
      _set(status: AuthStatus.unauthenticated);
    }
  }

  Future<bool> login(String username, String password) async {
    _errorCode = null;
    _set(busy: true, error: null);
    try {
      await api.login(username.trim(), password);
      _user = await api.fetchMe();
      _set(status: AuthStatus.authenticated, busy: false);
      return true;
    } on ApiException catch (e) {
      // 403 PENDING_APPROVAL / REGISTRATION_REJECTED are login outcomes, not an
      // expired session: nothing is cleared and no refresh is attempted.
      _errorCode = e.code;
      _set(busy: false, error: e.message);
      return false;
    } catch (_) {
      _set(busy: false, error: 'Could not reach the server. Check your connection.');
      return false;
    }
  }

  /// Hide the last login failure (e.g. when leaving the login screen).
  void clearError() {
    if (_error == null && _errorCode == null) return;
    _errorCode = null;
    _set(error: null);
  }

  Future<void> logout() async {
    await api.logout();
    _user = null;
    _errorCode = null;
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
    notifyListeners();
  }

  /// Update just the cached photo URL (null = removed).
  void setPhoto(String? url) {
    final current = _user;
    if (current == null) return;
    _user = current.copyWith(profileImage: url, clearPhoto: url == null);
    notifyListeners();
  }

  void _handleSessionExpired() {
    _user = null;
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
