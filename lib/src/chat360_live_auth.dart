import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// An access/refresh token pair for a Chat360 agent session.
@immutable
class Chat360Tokens {
  const Chat360Tokens({required this.accessToken, required this.refreshToken});

  final String accessToken;
  final String refreshToken;
}

/// Thrown by [Chat360LiveAuth.login] when the login call itself fails (bad
/// credentials, network error, unexpected response shape).
class Chat360LiveAuthException implements Exception {
  const Chat360LiveAuthException(this.message);

  final String message;

  @override
  String toString() => 'Chat360LiveAuthException: $message';
}

/// Owns the whole Chat360 agent session lifecycle: login, logout, silent
/// token refresh, and FCM registration — so a host app calls [login] and
/// [logout] at the same moments its own session starts and ends, and never
/// has to think about Chat360 tokens again after that.
///
/// This is a true singleton: [Chat360LiveAuth] and [Chat360LiveAuth.withTokens]
/// are both factories that return the *same* instance on every call,
/// however many times or from wherever they're invoked. There is exactly
/// one Chat360 session in a running app — matching the real constraint
/// that only one agent can be logged in through this SDK at a time — so
/// nothing in the app can accidentally end up holding two [Chat360LiveAuth]s
/// with two different sessions. The first call's [baseUrl] and [appId]
/// (and [httpClient]/[storage], for tests) are the ones that stick; later
/// calls ignore theirs and just return the existing instance. Call
/// [Chat360LiveAuth.reset] (test-only) to force a fresh instance.
///
/// The session (tokens, email, and which FCM token is currently
/// registered) is persisted to [FlutterSecureStorage] and restored when
/// the singleton is first created, so an agent stays signed in across app
/// restarts and [logout] can still unregister a token that was registered
/// in a previous run of the app. Restoration is async — see [isRestoring].
///
/// It's a [ChangeNotifier] so a widget can rebuild when [tokens] changes
/// (e.g. on [logout], when a refresh discovers the session is dead, or
/// once a persisted session finishes restoring).
class Chat360LiveAuth extends ChangeNotifier {
  Chat360LiveAuth._create({
    required this.baseUrl,
    required this.appId,
    required http.Client httpClient,
    required FlutterSecureStorage storage,
  })  : _http = httpClient,
        _storage = storage {
    _restore();
  }

  static Chat360LiveAuth? _instance;

  /// The app's single Chat360 session. The first call creates it; every
  /// call after that — from anywhere in the app — returns that same
  /// instance, ignoring whatever arguments it's given.
  ///
  /// [appId] identifies this integration's SDK credentials, as created by
  /// the Chat360 admin portal (`POST /api/mobile/sdk-notification-cred`) —
  /// pass it so FCM registration stores this app's tokens on that
  /// integration's own row instead of the Chat360 inhouse app's. Leave it
  /// null only when embedding this SDK *as* the Chat360 inhouse app.
  factory Chat360LiveAuth({
    String baseUrl = 'https://app.chat360.io',
    String? appId,
    http.Client? httpClient,
    FlutterSecureStorage? storage,
  }) {
    return _instance ??= Chat360LiveAuth._create(
      baseUrl: baseUrl,
      appId: appId,
      httpClient: httpClient ?? http.Client(),
      storage: storage ?? const FlutterSecureStorage(),
    );
  }

  /// For a host that already has a valid access/refresh pair from
  /// somewhere else (its own SSO, say) rather than a Chat360 email and
  /// password to pass to [login]. Refresh, logout, and FCM registration
  /// all work the same as if [login] had produced these tokens.
  ///
  /// Like the default constructor, this returns the app's single
  /// [Chat360LiveAuth] — if one already exists, [tokens] simply replaces its
  /// current session (persisted right away) rather than creating a second
  /// instance.
  factory Chat360LiveAuth.withTokens(
    Chat360Tokens tokens, {
    String baseUrl = 'https://app.chat360.io',
    String? appId,
    http.Client? httpClient,
    FlutterSecureStorage? storage,
  }) {
    final instance = Chat360LiveAuth(
      baseUrl: baseUrl,
      appId: appId,
      httpClient: httpClient,
      storage: storage,
    );
    instance._tokens = tokens;
    instance._isRestoring = false;
    unawaited(instance._persist());
    instance.notifyListeners();
    return instance;
  }

  /// Test-only: drops the singleton so the next [Chat360LiveAuth] call creates
  /// a fresh instance. Never call this from app code — the whole point of
  /// the singleton is that production code never gets a second session.
  @visibleForTesting
  static void reset() {
    _instance = null;
  }

  static const _accessKey = 'chat360_access_token';
  static const _refreshKey = 'chat360_refresh_token';
  static const _emailKey = 'chat360_email';
  static const _fcmKey = 'chat360_registered_fcm_token';

  /// The console's web origin — the same one passed to
  /// [Chat360LiveChatSDK.baseUrl]. API calls are made against
  /// `$baseUrl/api/...`.
  final String baseUrl;

  /// This integration's `app_id`, as created by the Chat360 admin portal —
  /// see [Chat360LiveAuth]'s constructor docs. Sent on every
  /// `mobile/notify` register/unregister call; omitted (inhouse) when null.
  final String? appId;

  final http.Client _http;
  final FlutterSecureStorage _storage;

  Chat360Tokens? _tokens;

  /// The current session, or null if signed out.
  Chat360Tokens? get tokens => _tokens;

  bool _isRestoring = true;

  /// True until a persisted session (if any) has been loaded from secure
  /// storage. [Chat360LiveChatSDK] treats this as "still figuring out
  /// whether there's a session", not as signed out — showing a signed-out
  /// state before this finishes would flash it even for an agent who was,
  /// and still is, logged in.
  bool get isRestoring => _isRestoring;

  String? _email;
  String? _registeredFcmToken;

  @override
  void dispose() {
    // A disposed ChangeNotifier throws if used again, so a disposed
    // singleton has to stop being *the* singleton — otherwise the next
    // Chat360LiveAuth() call anywhere in the app would hand back a dead
    // instance instead of a usable session.
    if (identical(_instance, this)) _instance = null;
    super.dispose();
  }

  Uri _api(String path) => Uri.parse('$baseUrl/api/$path');

  Future<void> _restore() async {
    final access = await _storage.read(key: _accessKey);
    final refresh = await _storage.read(key: _refreshKey);
    final email = await _storage.read(key: _emailKey);
    final fcmToken = await _storage.read(key: _fcmKey);
    // Since this class is a singleton, the disk reads above can finish
    // after Chat360LiveAuth.withTokens (or an unusually fast login()) has
    // already given this instance a session — don't clobber it with
    // whatever was (or wasn't) on disk from before.
    if (_tokens == null) {
      _email = email;
      _registeredFcmToken = fcmToken;
      if (access != null && refresh != null) {
        _tokens = Chat360Tokens(accessToken: access, refreshToken: refresh);
      }
    }
    _isRestoring = false;
    notifyListeners();
  }

  Future<void> _persist() async {
    final current = _tokens;
    if (current == null) {
      await Future.wait([
        _storage.delete(key: _accessKey),
        _storage.delete(key: _refreshKey),
        _storage.delete(key: _emailKey),
        _storage.delete(key: _fcmKey),
      ]);
      return;
    }
    await Future.wait([
      _storage.write(key: _accessKey, value: current.accessToken),
      _storage.write(key: _refreshKey, value: current.refreshToken),
      if (_email != null) _storage.write(key: _emailKey, value: _email!),
      if (_registeredFcmToken != null)
        _storage.write(key: _fcmKey, value: _registeredFcmToken!)
      else
        _storage.delete(key: _fcmKey),
    ]);
  }

  /// Logs in with the agent's Chat360 credentials via `auth/wesite-login-user`.
  ///
  /// Pass [fcmToken] (obtained from the host's own Firebase setup — this
  /// class never touches Firebase itself) to register it for push via
  /// `mobile/notify` right away. Throws [Chat360LiveAuthException] on failure;
  /// callers should keep their own UI up until this resolves.
  Future<Chat360Tokens> login({
    required String email,
    required String password,
    String? fcmToken,
  }) async {
    final response = await _http.post(
      _api('auth/wesite-login-user'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'decrypt': false,
        'login_confirmation': false,
        'email': email,
        'password': password,
        'mobile': true,
      }),
    );
    if (response.statusCode != 200) {
      throw Chat360LiveAuthException(
        'Login failed (${response.statusCode}): ${response.body}',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final tokens = Chat360Tokens(
      accessToken: body['access'] as String,
      refreshToken: body['refresh'] as String,
    );
    _tokens = tokens;
    _email = (body['user_email'] as String?) ?? email;
    await _persist();
    notifyListeners();

    if (fcmToken != null) {
      await _registerFcm(fcmToken);
    }
    return tokens;
  }

  /// Logs out via `auth/logout`, unregisters the FCM token if one was
  /// registered at [login] — even in a previous run of the app, since that
  /// registration is persisted — and clears the local session regardless
  /// of whether those network calls succeed: a host calling this expects
  /// the session gone either way.
  Future<void> logout() async {
    final current = _tokens;
    if (current == null) return;

    if (_registeredFcmToken != null) {
      await _unregisterFcm(_registeredFcmToken!);
    }
    try {
      await _http.get(
        _api('auth/logout').replace(
          queryParameters: {'refresh_token': current.refreshToken},
        ),
      );
    } catch (_) {
      // Best-effort — proceed to clear the local session regardless.
    }

    _tokens = null;
    _email = null;
    _registeredFcmToken = null;
    await _persist();
    notifyListeners();
  }

  /// Silently refreshes the access token via `auth/token/refresh/`.
  ///
  /// Called by [Chat360LiveChatSDK] when it can't verify a working
  /// session — this is the normal, expected path for an expired access
  /// token and never needs the host involved. Returns null only when the
  /// *refresh* token itself is rejected, which means the session is
  /// genuinely over and only a real [login] can recover it; when that
  /// happens, [tokens] is cleared and listeners are notified, same as
  /// [logout].
  Future<Chat360Tokens?> refresh() async {
    final current = _tokens;
    if (current == null) return null;

    final response = await _http.post(
      _api('auth/token/refresh/'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'refresh': current.refreshToken}),
    );
    if (response.statusCode != 200) {
      _tokens = null;
      await _persist();
      notifyListeners();
      return null;
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final refreshed = Chat360Tokens(
      accessToken: body['access'] as String,
      refreshToken: current.refreshToken,
    );
    _tokens = refreshed;
    await _persist();
    notifyListeners();
    return refreshed;
  }

  Future<void> _registerFcm(String fcmToken) async {
    final email = await _resolveEmail();
    final accessToken = _tokens?.accessToken;
    if (email == null || accessToken == null) return;

    final response = await _http.post(
      _api('mobile/notify'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $accessToken',
      },
      body: jsonEncode({
        'email': email,
        'fcm_token': fcmToken,
        'device_type': Platform.isAndroid ? 'android' : 'ios',
        if (appId != null) 'app_id': appId,
      }),
    );
    if (response.statusCode == 200) {
      _registeredFcmToken = fcmToken;
      await _persist();
    } else {
      // Best-effort, same as elsewhere — but a non-200 here (e.g. "SDK not
      // found" from a wrong/deleted appId) is a config bug worth surfacing
      // during integration rather than failing silently forever.
      debugPrint(
        'Chat360LiveAuth: FCM registration failed '
        '(${response.statusCode}): ${response.body}',
      );
    }
  }

  Future<void> _unregisterFcm(String fcmToken) async {
    final email = _email ?? await _resolveEmail();
    final accessToken = _tokens?.accessToken;
    if (email == null || accessToken == null) return;

    await _http.delete(
      _api('mobile/notify'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $accessToken',
      },
      body: jsonEncode({
        'email': email,
        'fcm_token': fcmToken,
        'device_type': Platform.isAndroid ? 'android' : 'ios',
        if (appId != null) 'app_id': appId,
      }),
    );
  }

  Future<String?> _resolveEmail() async {
    if (_email != null) return _email;
    final current = _tokens;
    if (current == null) return null;

    final response = await _http.get(
      _api('auth/user'),
      headers: {'Authorization': 'Bearer ${current.accessToken}'},
    );
    if (response.statusCode != 200) return null;

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    _email = body['email'] as String?;
    await _persist();
    return _email;
  }
}
