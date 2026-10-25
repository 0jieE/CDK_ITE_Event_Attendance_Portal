import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/student_profile.dart';
import '../models/user.dart';
import '../utils/errors.dart';
import 'api_service.dart';
import 'connectivity_service.dart';
import 'offline_credentials.dart';

enum AuthStatus { unknown, unauthenticated, authenticated }

/// Single source of truth for auth state. Owns the [ApiService] and reacts to
/// irrecoverable session expiry by dropping back to the unauthenticated state.
///
/// **Offline sessions.** With [offlineLogin] set, an instructor or student who
/// has signed in online on this phone can sign in again with no connection
/// (see [OfflineCredentials]). That gives the app's offline features only:
/// there is no server session behind it ([offlineSession] is true). When the
/// connection comes back the session is re-checked: a still-valid server
/// session carries on as online; otherwise the user is sent to the login
/// screen (username filled in, [notice] explaining) and must sign in online.
/// Anything saved offline (queued scans) stays on the phone until then.
class AuthProvider extends ChangeNotifier {
  final ApiService api;
  final OfflineCredentials? offlineLogin;
  final ConnectivityService? connectivity;

  /// Which accounts may use this app (default: instructors and students),
  /// and what others are told at sign-in.
  final bool Function(User user)? allowedUser;
  final String notAllowedMessage;

  AuthStatus _status = AuthStatus.unknown;
  User? _userValue;

  /// The signed-in user; also decides whose saved data the API reads.
  User? get _user => _userValue;
  set _user(User? u) {
    _userValue = u;
    api.cacheOwner = u?.id;
  }

  /// Called each time a real (online) session starts or resumes, so the app
  /// can download what it needs for offline use.
  void Function(User user)? onOnlineSession;
  String? _error;
  String? _notice;
  String? _lastUsername;
  bool _busy = false;
  bool _offlineSession = false;
  bool _revalidating = false;
  bool _wasOnline = true;

  AuthProvider({
    ApiService? apiService,
    this.offlineLogin,
    this.connectivity,
    this.allowedUser,
    this.notAllowedMessage = "This account can't use this app.",
  }) : api = apiService ?? ApiService() {
    api.onUnauthorized = _handleSessionExpired;
    final c = connectivity;
    if (c != null) {
      _wasOnline = c.isOnline;
      c.addListener(_onConnectivity);
    }
  }

  bool _allowed(User u) =>
      allowedUser?.call(u) ?? (u.isInstructor || u.isStudent);

  AuthStatus get status => _status;
  User? get user => _user;
  String? get error => _error;
  bool get busy => _busy;

  /// Signed in on the phone only (no server session yet).
  bool get offlineSession => _offlineSession;

  /// Information for the login screen (not an error), e.g. "back online".
  String? get notice => _notice;

  /// The account to pre-fill on the login screen.
  String? get lastUsername => _lastUsername;

  static const _kUser = 'auth:user';

  static const _backOnline =
      "You're back online. Sign in again to continue. Anything saved on this "
      'phone (like offline scans) stays and syncs after you sign in.';

  /// On launch: if we have a token, validate it via /me/; else go to login.
  /// With no connection the last signed-in user is used, so the app still
  /// opens offline (the server re-checks the session on the next request).
  Future<void> bootstrap() async {
    if (!await api.hasToken) {
      _set(status: AuthStatus.unauthenticated);
      return;
    }
    try {
      final me = await api.fetchMe();
      if (!_allowed(me)) {
        await api.logout();
        _set(status: AuthStatus.unauthenticated, error: notAllowedMessage);
        return;
      }
      _user = me;
      await _cacheUser();
      unawaited(_dropStaleOfflineLogin(_user!));
      _set(status: AuthStatus.authenticated);
      onOnlineSession?.call(_user!);
    } catch (e) {
      // So the reconnect is noticed (and the session re-checked) later.
      if (isNetworkError(e)) connectivity?.reportUnreachable();
      final cached = isNetworkError(e) ? await _cachedUser() : null;
      if (cached != null && _allowed(cached)) {
        _user = cached;
        _offlineSession = true;
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

  /// Sign in online; with no connection, fall back to an offline sign-in for
  /// an account that has signed in online on this phone before.
  Future<bool> login(String username, String password) async {
    final name = username.trim();
    _set(busy: true, error: null, notice: null);
    final offline = offlineLogin;
    final knownOffline = !(connectivity?.isOnline ?? true);

    if (!knownOffline || offline == null) {
      // With an offline fallback ready, don't wait for ever on a dead network.
      final canFallBack = offline != null && await offline.has(name);
      try {
        final signIn = api.login(name, password);
        await (canFallBack
            ? signIn.timeout(const Duration(seconds: 20))
            : signIn);
        final me = await api.fetchMe();
        if (!_allowed(me)) {
          await api.logout();
          if (offline != null) {
            unawaited(offline.forget(name).catchError((_) {}));
          }
          _set(
            status: AuthStatus.unauthenticated,
            busy: false,
            error: notAllowedMessage,
          );
          return false;
        }
        _user = me;
        _offlineSession = false;
        _lastUsername = name;
        await _cacheUser();
        connectivity?.reportReachable();
        if (offline != null) {
          // Only the app's own roles may sign in offline later.
          unawaited(
            (_allowed(me)
                    ? offline.remember(name, password, me)
                    : offline.forget(name))
                .catchError((_) {}),
          );
        }
        _set(status: AuthStatus.authenticated, busy: false);
        onOnlineSession?.call(me);
        return true;
      } on ApiException catch (e) {
        // The server refused the password this phone remembers: it was
        // changed, or the account was disabled. A typo keeps offline sign-in.
        if (e.statusCode == 401 && offline != null) {
          unawaited(offline.forgetIfMatches(name, password).catchError((_) {}));
        }
        _set(busy: false, error: e.message);
        return false;
      } catch (e) {
        if (!isNetworkError(e) || offline == null) {
          _set(
            busy: false,
            error: 'Could not reach the server. Check your connection.',
          );
          return false;
        }
        connectivity?.reportUnreachable();
      }
    }

    // No connection: sign in on the phone.
    final result = await offline.verify(name, password);
    final user = result.user;
    if (user == null) {
      _set(busy: false, error: result.message);
      return false;
    }
    if (!_allowed(user)) {
      _set(
        status: AuthStatus.unauthenticated,
        busy: false,
        error: notAllowedMessage,
      );
      return false;
    }
    _user = user;
    _offlineSession = true;
    _lastUsername = name;
    _set(status: AuthStatus.authenticated, busy: false);
    return true;
  }

  /// Back online during an offline session: does a server session still
  /// stand behind it? Called on reconnect; safe to call any time.
  Future<void> revalidate() async {
    if (!_offlineSession || _revalidating || _user == null) return;
    _revalidating = true;
    try {
      if (!await api.hasToken) {
        _requireOnlineSignIn();
        return;
      }
      final me = await api.fetchMe().timeout(const Duration(seconds: 20));
      if (me.id != _user?.id || !_allowed(me)) {
        await logout();
        return;
      }
      if (await _dropStaleOfflineLogin(me)) {
        // Password changed elsewhere: the old session must not carry on.
        await api.logout();
        _requireOnlineSignIn();
        return;
      }
      _user = me;
      _offlineSession = false;
      await _cacheUser();
      connectivity?.reportReachable();
      notifyListeners();
      onOnlineSession?.call(me);
    } on SessionExpired {
      // Already handled: _handleSessionExpired sent the user to sign in.
    } catch (e) {
      if (isNetworkError(e)) connectivity?.reportUnreachable();
      // Otherwise the server had a problem: stay offline, retry next time.
    } finally {
      _revalidating = false;
    }
  }

  /// When the server reports a different password version than the one
  /// stored for offline sign-in, forget the stored one. True if dropped.
  Future<bool> _dropStaleOfflineLogin(User me) async {
    final offline = offlineLogin;
    final current = me.passwordVersion;
    if (offline == null || current == null) return false;
    try {
      final stored = (await offline.storedUser(me.username))?.passwordVersion;
      if (stored == null || stored == current) return false;
      await offline.forget(me.username);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _onConnectivity() {
    final online = connectivity!.isOnline;
    if (online && !_wasOnline && _offlineSession) unawaited(revalidate());
    _wasOnline = online;
  }

  /// End an offline session that has no server session behind it.
  void _requireOnlineSignIn() {
    _lastUsername = _user?.username ?? _lastUsername;
    _user = null;
    _offlineSession = false;
    _set(status: AuthStatus.unauthenticated, error: null, notice: _backOnline);
  }

  /// After the password was changed in the app: remember the new one for
  /// offline sign-in (with the profile's new password version).
  Future<void> passwordChanged(String newPassword) async {
    final offline = offlineLogin;
    final user = _user;
    if (offline == null || user == null) return;
    try {
      final me = await api.fetchMe();
      _user = me;
      await offline.remember(me.username, newPassword, me);
    } catch (_) {
      await offline
          .remember(user.username, newPassword, user)
          .catchError((_) {});
    }
  }

  /// Hide the last login failure (e.g. when leaving the login screen).
  void clearError() {
    if (_error == null) return;
    _set(error: null);
  }

  /// Sign out. Offline sign-in stays available on this phone unless
  /// [forgetDevice] is set. Queued offline scans are kept either way.
  Future<void> logout({bool forgetDevice = false}) async {
    final username = _user?.username;
    final id = _user?.id;
    await api.logout();
    await api.cache.remove(_kUser);
    if (forgetDevice && username != null) {
      await offlineLogin?.forget(username).catchError((_) {});
      if (id != null) {
        // Saved screens too (queued scans are kept: they still have to sync).
        await api.clearCacheFor(id);
        await api.cache.removeWhere((k) => k.startsWith('student:$id:'));
      }
    }
    _lastUsername = forgetDevice ? null : username;
    _user = null;
    _offlineSession = false;
    _set(status: AuthStatus.unauthenticated, error: null, notice: null);
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
    if (_offlineSession) {
      _requireOnlineSignIn();
      return;
    }
    _lastUsername = _user?.username ?? _lastUsername;
    _user = null;
    api.cache.remove(_kUser);
    _set(status: AuthStatus.unauthenticated);
  }

  void _set({
    AuthStatus? status,
    bool? busy,
    Object? error = _sentinel,
    Object? notice = _sentinel,
  }) {
    if (status != null) _status = status;
    if (busy != null) _busy = busy;
    if (!identical(error, _sentinel)) _error = error as String?;
    if (!identical(notice, _sentinel)) _notice = notice as String?;
    notifyListeners();
  }

  static const _sentinel = Object();

  @override
  void dispose() {
    connectivity?.removeListener(_onConnectivity);
    super.dispose();
  }
}
