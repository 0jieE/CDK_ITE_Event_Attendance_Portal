import 'package:flutter/foundation.dart';

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
  bool _busy = false;

  AuthProvider({ApiService? apiService}) : api = apiService ?? ApiService() {
    api.onUnauthorized = _handleSessionExpired;
  }

  AuthStatus get status => _status;
  User? get user => _user;
  String? get error => _error;
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
    _set(busy: true, error: null);
    try {
      await api.login(username.trim(), password);
      _user = await api.fetchMe();
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

  Future<void> logout() async {
    await api.logout();
    _user = null;
    _set(status: AuthStatus.unauthenticated, error: null);
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
