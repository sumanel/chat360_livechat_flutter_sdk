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

/// An OEM mobile SSO credential to exchange for a Chat360 session via
/// `POST /api/campaign-oem/sso/login` — see [Chat360LiveAuth.withJWT].
///
/// v0 supports only `clientId: "heromotocorp"`. For that client, [extra]
/// must contain non-blank `loginId`, `dealerCode`, and `divisionName`
/// entries, matching what the OEM app already holds from Hero's own login.
@immutable
class Chat360JWTTokens {
  const Chat360JWTTokens({
    required this.clientId,
    required this.jwtToken,
    this.extra = const {},
  });

  /// Must be `"heromotocorp"` in v0 — any other value is rejected server-side.
  final String clientId;

  /// The OEM's own JWT (e.g. Hero's), forwarded as-is for verification.
  final String jwtToken;

  /// Client-specific fields required alongside [jwtToken]. For
  /// `heromotocorp`: `loginId`, `dealerCode`, `divisionName`.
  final Map<String, String> extra;
}

/// Minimal persistence seam [Chat360LiveAuth] stores its session through —
/// implemented by [FlutterSecureStorage] for real use (the default), or a
/// fake for tests. Exists because [FlutterSecureStorage] itself is a
/// concrete platform-channel wrapper with no test-friendly seam of its own;
/// this lets `storage:` on [Chat360LiveAuth]'s constructors take a fake
/// in-memory implementation in tests instead.
abstract class Chat360SecureStore {
  Future<String?> read({required String key});
  Future<void> write({required String key, required String value});
  Future<void> delete({required String key});
}

class _FlutterSecureStore implements Chat360SecureStore {
  const _FlutterSecureStore(this._storage);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read({required String key}) => _storage.read(key: key);

  @override
  Future<void> write({required String key, required String value}) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete({required String key}) => _storage.delete(key: key);
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
/// with two different sessions. The first call's [appId]
/// (and [httpClient]/[storage], for tests) are the ones that stick; later
/// calls ignore theirs and just return the existing instance. Use
/// [updateBaseUrl] to change the console origin on that existing instance.
/// Call [Chat360LiveAuth.reset] (test-only) to force a fresh instance.
///
/// A host is expected to call [logout] before a different agent signs in
/// on the same device, but [login], [withJWT], and [withTokens] don't
/// depend on that happening: each one best-effort ends whatever session is
/// currently active — invalidating its refresh token and unregistering its
/// FCM token — before adopting the new one. Without that, an agent who
/// never tapped "log out" (app killed, device handed to a teammate) would
/// leave their refresh token live and their FCM registration in place, so
/// this device could keep receiving push notifications meant for them even
/// after someone else signs in.
///
/// The session (tokens, email, and which FCM token is currently
/// registered) is persisted to [FlutterSecureStorage] and restored when
/// the singleton is first created, so an agent stays signed in across app
/// restarts and [logout] can still unregister a token that was registered
/// in a previous run of the app. Restoration is async — see [isRestoring].
///
/// It's a [ChangeNotifier] so a widget can rebuild when [tokens] changes
/// (e.g. on [logout], when a refresh discovers the session is dead, or
/// once a persisted session finishes restoring) — but that alone can't
/// tell a host *why* it changed. For the specific case of the agent having
/// been signed out on Chat360's side rather than by this app (an admin
/// force-logout, a revoked session, etc.), set [onSessionExpired] to react
/// to that on its own, e.g. outside whatever screen [Chat360LiveChatSDK]
/// happens to be showing.
class Chat360LiveAuth extends ChangeNotifier {
  Chat360LiveAuth._create({
    required String baseUrl,
    required this.appId,
    required http.Client httpClient,
    required Chat360SecureStore storage,
  })  : _baseUrl = _normalizeBaseUrl(baseUrl),
        _http = httpClient,
        _storage = storage {
    _restore();
  }

  static Chat360LiveAuth? _instance;

  /// The app's single Chat360 session. The first call creates it; every
  /// call after that — from anywhere in the app — returns that same
  /// instance. Constructor arguments for an existing instance are ignored;
  /// use [updateBaseUrl] to change its console origin.
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
    Chat360SecureStore? storage,
  }) {
    return _instance ??= Chat360LiveAuth._create(
      baseUrl: baseUrl,
      appId: appId,
      httpClient: httpClient ?? http.Client(),
      storage: storage ?? const _FlutterSecureStore(FlutterSecureStorage()),
    );
  }

  /// For a host that already has a valid access/refresh pair from
  /// somewhere else (its own SSO, say) rather than a Chat360 email and
  /// password to pass to [login]. Refresh, logout, and FCM registration
  /// all work the same as if [login] had produced these tokens.
  ///
  /// Pass [fcmToken] (obtained from the host's own Firebase setup) to
  /// register it for push via `mobile/notify` right away, same as [login]'s
  /// own [fcmToken] parameter.
  ///
  /// Like the default constructor, this returns the app's single
  /// [Chat360LiveAuth] — if one already exists, [tokens] simply replaces its
  /// current session (persisted right away) rather than creating a second
  /// instance.
  factory Chat360LiveAuth.withTokens(
    Chat360Tokens tokens, {
    String baseUrl = 'https://app.chat360.io',
    String? appId,
    String? fcmToken,
    http.Client? httpClient,
    Chat360SecureStore? storage,
  }) {
    final instance = Chat360LiveAuth(
      baseUrl: baseUrl,
      appId: appId,
      httpClient: httpClient,
      storage: storage,
    );
    final previousTokens = instance._tokens;
    final previousEmail = instance._email;
    final previousFcm = instance._registeredFcmToken;
    final previousBaseUrl = instance._sessionBaseUrl ?? instance._baseUrl;

    instance._tokens = tokens;
    instance._registeredFcmToken = null;
    instance._sessionBaseUrl = instance._baseUrl;
    instance._isRestoringFromStorage = false;
    unawaited(instance._persist());
    instance.notifyListeners();
    if (previousTokens != null) {
      unawaited(
        instance._endSession(
          previousTokens,
          baseUrl: previousBaseUrl,
          email: previousEmail,
          fcmToken: previousFcm,
        ),
      );
    }
    if (fcmToken != null) {
      unawaited(instance._registerFcm(fcmToken));
    }
    return instance;
  }

  /// For a host on the OEM mobile SSO path: it has an OEM JWT (e.g. Hero's)
  /// rather than a Chat360 email/password or an existing token pair, and
  /// needs [Chat360LiveAuth] to exchange it via
  /// `POST /api/campaign-oem/sso/login` before a session exists.
  ///
  /// Unlike [withTokens], this can't hand back a session synchronously —
  /// the exchange is a network call. It returns the singleton immediately,
  /// same as every other factory here, and performs the exchange in the
  /// background; [tokens] stays null and [isRestoring] stays true until it
  /// resolves, so callers (and [Chat360LiveChatSDK]) see the same "still
  /// figuring out the session" state they'd see while a persisted session
  /// is loading. On failure, [tokens] stays null and [lastSsoError] carries
  /// the API's `message` (or a network-error fallback) for the host to
  /// show — matching the API contract's "display message as-is".
  ///
  /// Pass [fcmToken] (obtained from the host's own Firebase setup) to
  /// register it for push via `mobile/notify` once the exchange succeeds,
  /// same as [login]'s own [fcmToken] parameter.
  factory Chat360LiveAuth.withJWT(
    Chat360JWTTokens jwt, {
    String baseUrl = 'https://app.chat360.io',
    String? appId,
    String? fcmToken,
    http.Client? httpClient,
    Chat360SecureStore? storage,
  }) {
    final instance = Chat360LiveAuth(
      baseUrl: baseUrl,
      appId: appId,
      httpClient: httpClient,
      storage: storage,
    );
    instance._isExchangingSso = true;
    unawaited(instance._loginWithOemSso(jwt, fcmToken: fcmToken));
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
  static const _sessionBaseUrlKey = 'chat360_session_base_url';

  /// The console's web origin used by both the SDK WebView and API calls.
  /// API calls are made against `$baseUrl/api/...`.
  String get baseUrl => _baseUrl;

  String _baseUrl;

  /// The [baseUrl] the currently-held [tokens] are actually valid for — set
  /// alongside [_tokens] every time a session is established (login,
  /// [withTokens], [withJWT], or restoring a persisted one) and persisted
  /// with it, so a later app launch that restores those tokens also knows
  /// which host they belong to instead of assuming whatever [baseUrl] this
  /// run happened to be constructed with. Null exactly when [_tokens] is.
  String? _sessionBaseUrl;

  /// True once [updateBaseUrl] has been called explicitly — stops [_restore]
  /// from overwriting that explicit choice with whatever base URL a
  /// persisted session (still loading from disk at the time) turns out to
  /// have been using.
  bool _baseUrlExplicitlySet = false;

  /// Changes the console origin used by future API calls and WebView loads.
  /// Since [Chat360LiveAuth] is a singleton, this is the supported way to
  /// change the origin after it already exists (e.g. a host reads a staging
  /// URL from its own UI and wants to point an already-constructed instance
  /// at it).
  ///
  /// A session belongs to exactly one [baseUrl] — see [_sessionBaseUrl] —
  /// so if [tokens] currently holds one established under a *different*
  /// origin than [baseUrl], calling this best-effort ends that session
  /// (invalidating its refresh token and unregistering its FCM token
  /// against the origin it actually belongs to, not the new one) and clears
  /// it locally, the same as [logout], before adopting the new origin.
  /// Without that, continuing to send that session's tokens to a different
  /// backend after switching would silently fail every call, or worse,
  /// coincidentally succeed against unrelated data if the new origin reuses
  /// token formats. Calling this with the same origin [baseUrl] already has
  /// is a no-op.
  void updateBaseUrl(String baseUrl) {
    final normalized = _normalizeBaseUrl(baseUrl);
    _baseUrlExplicitlySet = true;
    if (normalized == _baseUrl) return;

    final previousTokens = _tokens;
    final previousEmail = _email;
    final previousFcm = _registeredFcmToken;
    // Falls back to the origin baseUrl was just changed *from* — the
    // ordinary case, and the only one possible unless a session was
    // restored under an older SDK version that never persisted this.
    final previousBaseUrl = _sessionBaseUrl ?? _baseUrl;
    _baseUrl = normalized;
    if (previousTokens == null) return;

    _tokens = null;
    _email = null;
    _registeredFcmToken = null;
    _sessionBaseUrl = null;
    unawaited(_persist());
    notifyListeners();
    unawaited(
      _endSession(
        previousTokens,
        baseUrl: previousBaseUrl,
        email: previousEmail,
        fcmToken: previousFcm,
      ),
    );
  }

  /// This integration's `app_id`, as created by the Chat360 admin portal —
  /// see [Chat360LiveAuth]'s constructor docs. Sent on every
  /// `mobile/notify` register/unregister call; omitted (inhouse) when null.
  final String? appId;

  final http.Client _http;
  final Chat360SecureStore _storage;

  Chat360Tokens? _tokens;

  /// The current session, or null if signed out.
  Chat360Tokens? get tokens => _tokens;

  bool _isRestoringFromStorage = true;
  bool _isExchangingSso = false;

  /// True until a persisted session (if any) has been loaded from secure
  /// storage, and, if [Chat360LiveAuth.withJWT] kicked off an OEM SSO
  /// exchange, until that resolves too. [Chat360LiveChatSDK] treats this as
  /// "still figuring out whether there's a session", not as signed out —
  /// showing a signed-out state before this finishes would flash it even
  /// for an agent who was, and still is, logged in (or about to be, via
  /// SSO).
  bool get isRestoring => _isRestoringFromStorage || _isExchangingSso;

  /// The API's `message` from the most recent failed
  /// [Chat360LiveAuth.withJWT] exchange, e.g. `"Dealer mapping not found
  /// for this login."`. Null if there's never been a failed exchange, or a
  /// later one succeeded. The OEM SSO API contract calls for showing this
  /// string to the user as-is.
  String? lastSsoError;

  /// Called when a session ends because the server rejected its refresh
  /// token — i.e. the agent was signed out on Chat360's side (revoked,
  /// deactivated, forced out by an admin, or any other reason the backend
  /// considers the session dead) rather than by this app calling [logout].
  /// [tokens] is already null by the time this fires, same as it would be
  /// after [logout].
  ///
  /// A plain mutable field rather than a constructor parameter, so any code
  /// holding the singleton can set it — not just whichever call happened to
  /// construct it first. [Chat360LiveChatSDK] already reacts to this same
  /// event within its own view (falling back to [Chat360LiveChatSDK.authErrorBuilder]);
  /// set this when the host needs to react *outside* that view too — for
  /// example navigating back to its own login screen, clearing app state
  /// that assumed the agent was signed in, or showing a "you were signed
  /// out" message somewhere [Chat360LiveChatSDK] isn't even on screen to
  /// show one itself.
  ///
  /// Never called from [logout] itself (the caller already knows why the
  /// session ended), from [updateBaseUrl] switching a session away to a
  /// different origin (also host-initiated), or from a [refresh] that
  /// failed only because of a network error (the session isn't known to be
  /// dead, just unreachable right now — see [refresh]'s own doc).
  VoidCallback? onSessionExpired;

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

  static String _normalizeBaseUrl(String baseUrl) {
    final normalized = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    return normalized.isEmpty ? 'https://app.chat360.io' : normalized;
  }

  // Trims a trailing slash so a baseUrl given as e.g.
  // "https://dev-oem.chat360.io/" doesn't double up with the leading slash
  // here (".../api/..." becoming "..//api/...", which some server routers
  // 404 on). Takes an explicit [baseUrl] override (rather than always
  // reading the mutable [_baseUrl]) so a call acting on a *previous*
  // session — e.g. [_endSession] tearing one down after [updateBaseUrl]
  // already moved [_baseUrl] on — still targets the host that session
  // actually belongs to.
  Uri _api(String path, {String? baseUrl}) =>
      Uri.parse('${baseUrl ?? _baseUrl}/api/$path');

  Future<void> _restore() async {
    final access = await _storage.read(key: _accessKey);
    final refresh = await _storage.read(key: _refreshKey);
    final email = await _storage.read(key: _emailKey);
    final fcmToken = await _storage.read(key: _fcmKey);
    final sessionBaseUrl = await _storage.read(key: _sessionBaseUrlKey);
    // Since this class is a singleton, the disk reads above can finish
    // after Chat360LiveAuth.withTokens (or an unusually fast login()) has
    // already given this instance a session — don't clobber it with
    // whatever was (or wasn't) on disk from before. Chat360LiveAuth.withJWT
    // sets _tokens only once its network exchange resolves, which is far
    // slower than this local read — _isExchangingSso covers that gap so a
    // *previous* on-disk session (a different agent's, say) can't get
    // loaded and briefly used while the new SSO exchange is still in
    // flight.
    if (_tokens == null && !_isExchangingSso) {
      _email = email;
      _registeredFcmToken = fcmToken;
      if (access != null && refresh != null) {
        _tokens = Chat360Tokens(accessToken: access, refreshToken: refresh);
        _sessionBaseUrl = sessionBaseUrl ?? _baseUrl;
        // A restored session's own baseUrl wins over whatever this run
        // happened to construct/restore with — unless a host has already
        // explicitly chosen one via updateBaseUrl() in the meantime (a
        // synchronous call right after construction, before this async
        // read completes, beats this heuristic). Without this, restoring
        // tokens issued against e.g. dev-oem.chat360.io while this run
        // defaults to app.chat360.io would silently send them to the
        // wrong host.
        if (sessionBaseUrl != null && !_baseUrlExplicitlySet) {
          _baseUrl = _normalizeBaseUrl(sessionBaseUrl);
        }
      }
    }
    _isRestoringFromStorage = false;
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
        _storage.delete(key: _sessionBaseUrlKey),
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
      _storage.write(
        key: _sessionBaseUrlKey,
        value: _sessionBaseUrl ?? _baseUrl,
      ),
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

    final previousTokens = _tokens;
    final previousEmail = _email;
    final previousFcm = _registeredFcmToken;
    final previousBaseUrl = _sessionBaseUrl ?? _baseUrl;

    _tokens = tokens;
    _email = (body['user_email'] as String?) ?? email;
    _registeredFcmToken = null;
    _sessionBaseUrl = _baseUrl;
    await _persist();
    notifyListeners();

    if (previousTokens != null) {
      await _endSession(
        previousTokens,
        baseUrl: previousBaseUrl,
        email: previousEmail,
        fcmToken: previousFcm,
      );
    }
    if (fcmToken != null) {
      await _registerFcm(fcmToken);
    }
    return tokens;
  }

  /// Backs [Chat360LiveAuth.withJWT]: exchanges an OEM JWT for a Chat360
  /// session via `POST /api/campaign-oem/sso/login`. Every failure path in
  /// that API is a 400 with a `message` string, so — unlike [login], which
  /// throws — this stores it in [lastSsoError] instead: there's no caller
  /// left to catch an exception by the time this runs, since [withJWT]
  /// already returned the singleton before this started.
  Future<void> _loginWithOemSso(Chat360JWTTokens jwt,
      {String? fcmToken}) async {
    try {
      final response = await _http.post(
        _api('campaign-oem/sso/login'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({
          'clientId': jwt.clientId,
          'token': jwt.jwtToken,
          'extra': jwt.extra,
        }),
      );
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode != 200) {
        lastSsoError = (body['message'] as String?) ??
            'OEM SSO login failed (${response.statusCode}).';
        return;
      }
      lastSsoError = null;

      final previousTokens = _tokens;
      final previousEmail = _email;
      final previousFcm = _registeredFcmToken;
      final previousBaseUrl = _sessionBaseUrl ?? _baseUrl;

      _tokens = Chat360Tokens(
        accessToken: body['accessToken'] as String,
        refreshToken: body['refreshToken'] as String,
      );
      _registeredFcmToken = null;
      _sessionBaseUrl = _baseUrl;
      await _persist();

      if (previousTokens != null) {
        await _endSession(
          previousTokens,
          baseUrl: previousBaseUrl,
          email: previousEmail,
          fcmToken: previousFcm,
        );
      }
      if (fcmToken != null) {
        await _registerFcm(fcmToken);
      }
    } catch (_) {
      lastSsoError = 'Token validation failed.';
    } finally {
      _isExchangingSso = false;
      notifyListeners();
    }
  }

  /// Logs out via `auth/logout`, unregisters the FCM token if one was
  /// registered at [login] — even in a previous run of the app, since that
  /// registration is persisted — and clears the local session regardless
  /// of whether those network calls succeed: a host calling this expects
  /// the session gone either way.
  Future<void> logout() async {
    final current = _tokens;
    if (current == null) return;

    await _endSession(
      current,
      baseUrl: _sessionBaseUrl ?? _baseUrl,
      email: _email,
      fcmToken: _registeredFcmToken,
    );

    _tokens = null;
    _email = null;
    _registeredFcmToken = null;
    _sessionBaseUrl = null;
    await _persist();
    notifyListeners();
  }

  /// Best-effort server-side teardown of a session that's about to stop
  /// being *the* session — either because [logout] was called, or because
  /// [login]/[withJWT]/[withTokens]/[updateBaseUrl] is replacing it with a
  /// different one. Unregisters [fcmToken] (if any) and invalidates
  /// [tokens]' refresh token via `auth/logout`. Takes everything as
  /// explicit parameters rather than reading [_tokens]/[_baseUrl]/[_email]/
  /// [_registeredFcmToken] so it's safe to call after those fields have
  /// already been overwritten with a new session's values — as [login] etc.
  /// do, so a failed new-session network call never leaves the old session
  /// torn down for nothing, and so this targets the origin [tokens] was
  /// actually issued by even if [_baseUrl] has since moved on.
  Future<void> _endSession(
    Chat360Tokens tokens, {
    required String baseUrl,
    required String? email,
    required String? fcmToken,
  }) async {
    if (fcmToken != null && email != null) {
      await _unregisterFcmFor(
        baseUrl: baseUrl,
        email: email,
        accessToken: tokens.accessToken,
        fcmToken: fcmToken,
      );
    }
    try {
      await _http.get(
        _api('auth/logout', baseUrl: baseUrl).replace(
          queryParameters: {'refresh_token': tokens.refreshToken},
        ),
      );
    } catch (_) {
      // Best-effort — the new session (or the local logout) proceeds
      // regardless.
    }
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

    final http.Response response;
    try {
      response = await _http.post(
        _api('auth/token/refresh/'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({'refresh': current.refreshToken}),
      );
    } catch (e) {
      // A network failure isn't the refresh token being rejected — it
      // might work again in a second. Don't tear down a session that could
      // still be perfectly valid just because this one call couldn't
      // reach the server; the caller gets null either way and should treat
      // that as "can't proceed right now," not "signed out."
      debugPrint('Chat360LiveAuth: refresh failed (network): $e');
      return null;
    }
    if (response.statusCode != 200) {
      _tokens = null;
      _sessionBaseUrl = null;
      await _persist();
      notifyListeners();
      onSessionExpired?.call();
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

  /// Decodes a JWT's `exp` claim (seconds since epoch) without verifying
  /// its signature — this SDK only ever reads tokens it just received from
  /// its own trusted backend, so there's nothing to verify against. Returns
  /// null for anything that doesn't parse as a three-part JWT with a
  /// numeric `exp` claim, so an access token in some other shape just
  /// disables [ensureFreshTokens]'s proactive check rather than crashing.
  static DateTime? _jwtExpiry(String token) {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    try {
      final payload = jsonDecode(
              utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))))
          as Map<String, dynamic>;
      final exp = payload['exp'];
      if (exp is! int) return null;
      return DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true);
    } catch (_) {
      return null;
    }
  }

  /// Makes sure [tokens] actually works before a caller — typically
  /// [Chat360LiveChatSDK], right before it loads the WebView — relies on
  /// it, instead of finding out only after a WebView round-trip to a
  /// rejected page load. That reactive path can also simply miss a dead
  /// token altogether if the web console's own client-side routing swaps
  /// in its login view without a full page navigation — this check happens
  /// before the WebView is ever touched, so it can't have that gap.
  ///
  /// Two checks, cheapest first:
  /// 1. If the access token's own `exp` claim says it's already expired or
  ///    expiring within [buffer], skip straight to [refresh] — there's no
  ///    point asking the server to confirm what's already locally certain.
  /// 2. Otherwise — including when it isn't a JWT this can decode at all —
  ///    confirms the server still actually accepts it with a lightweight
  ///    `auth/user` call. A token can look perfectly unexpired by its own
  ///    claim yet already be dead server-side (revoked, superseded by a
  ///    login elsewhere, an admin forcing the agent out) — that claim is
  ///    only ever a *lower bound* on how long a token lasts, never a
  ///    guarantee, so trusting it alone reintroduces the exact gap this
  ///    method exists to close. Only [refresh]es if that check fails.
  ///
  /// A no-op — and safe to call unconditionally — when there's no session:
  /// [tokens] is returned unchanged without a network call. Returns null if
  /// a needed refresh failed for real (the refresh token itself was
  /// rejected) — [tokens] is already cleared then, same as [refresh]. A
  /// refresh that failed only because of a network error also returns
  /// null, but leaves the existing session in place to retry later.
  Future<Chat360Tokens?> ensureFreshTokens({
    Duration buffer = const Duration(seconds: 30),
  }) async {
    final current = _tokens;
    if (current == null) return null;

    final expiry = _jwtExpiry(current.accessToken);
    final locallyExpired =
        expiry != null && !expiry.isAfter(DateTime.now().toUtc().add(buffer));
    if (locallyExpired) return refresh();

    if (await _isAccepted(current.accessToken)) return current;
    return refresh();
  }

  /// Confirms the server still accepts [accessToken] right now, via a
  /// lightweight `auth/user` call — see [ensureFreshTokens]. A network
  /// failure here isn't the token being rejected, so it's treated as
  /// "can't tell, assume fine" rather than forcing an unnecessary refresh
  /// (or worse, being mistaken for a real rejection down the line).
  Future<bool> _isAccepted(String accessToken) async {
    try {
      final response = await _http.get(
        _api('auth/user'),
        headers: {'Authorization': 'Bearer $accessToken'},
      );
      if (response.statusCode == 200 && _email == null) {
        // Already had to make this call — might as well save _resolveEmail
        // (used for FCM registration) a redundant one later.
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        _email = body['email'] as String?;
      }
      return response.statusCode == 200;
    } catch (_) {
      return true;
    }
  }

  /// Never throws — every caller (`login`, `withTokens`, `withJWT`) treats
  /// FCM registration as a side effect of a session that's already
  /// established, not part of what makes login succeed or fail. A flaky
  /// network on this call shouldn't turn a successful sign-in into a
  /// reported failure, so any error here is logged and swallowed instead.
  Future<void> _registerFcm(String fcmToken) async {
    try {
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
        // Same best-effort spirit as the catch below — but a non-200 here
        // (e.g. "SDK not found" from a wrong/deleted appId) is a config bug
        // worth surfacing during integration rather than failing silently
        // forever.
        debugPrint(
          'Chat360LiveAuth: FCM registration failed '
          '(${response.statusCode}): ${response.body}',
        );
      }
    } catch (e) {
      debugPrint('Chat360LiveAuth: FCM registration failed: $e');
    }
  }

  /// Never throws, same best-effort spirit as [_registerFcm] — called from
  /// [logout]/[_endSession], which both need to keep clearing the local
  /// session regardless of whether this network call succeeds.
  Future<void> _unregisterFcmFor({
    required String baseUrl,
    required String email,
    required String accessToken,
    required String fcmToken,
  }) async {
    try {
      await _http.delete(
        _api('mobile/notify', baseUrl: baseUrl),
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
    } catch (e) {
      debugPrint('Chat360LiveAuth: FCM unregistration failed: $e');
    }
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
