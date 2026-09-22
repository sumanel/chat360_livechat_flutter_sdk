import 'dart:convert';

import 'package:chat360_livechat_sdk/chat360_livechat_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// In-memory stand-in for [Chat360SecureStore] — a real device's secure
/// storage without the platform channel, so state genuinely persists across
/// two [Chat360LiveAuth] instances the way it would across two app runs
/// (create a second instance backed by the same [_FakeSecureStore] to
/// simulate "the app restarted").
class _FakeSecureStore implements Chat360SecureStore {
  _FakeSecureStore([Map<String, String>? seed]) : data = seed ?? {};

  final Map<String, String> data;

  @override
  Future<String?> read({required String key}) async => data[key];

  @override
  Future<void> write({required String key, required String value}) async {
    data[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    data.remove(key);
  }
}

/// One request the fake HTTP layer saw, for assertions like "did the
/// teardown call actually go to the OLD host, not the new one."
class _Recorded {
  _Recorded(this.method, this.url, this.body);

  final String method;
  final Uri url;
  final String body;

  Map<String, dynamic> get json => jsonDecode(body) as Map<String, dynamic>;
}

/// Builds a [MockClient] that dispatches by exact `method path` (e.g.
/// `"POST /api/auth/wesite-login-user"`) to a canned [http.Response],
/// recording every request it sees into [log]. A method+path with no
/// registered response 404s, so a test only wires up the calls it expects
/// and gets a loud failure if the code under test makes an unexpected one.
http.Client _mockClient(
  Map<String, http.Response> responses, {
  List<_Recorded>? log,
}) {
  return MockClient((request) async {
    log?.add(_Recorded(request.method, request.url, request.body));
    final key = '${request.method} ${request.url.path}';
    final response = responses[key];
    if (response == null) {
      return http.Response('not stubbed: $key', 404);
    }
    return response;
  });
}

http.Response _ok(Map<String, dynamic> body) =>
    http.Response(jsonEncode(body), 200);

http.Response _fail(int status, [Map<String, dynamic>? body]) =>
    http.Response(body == null ? '' : jsonEncode(body), status);

/// A JWT with a given `exp` claim (seconds since epoch) and no real
/// signature — [Chat360LiveAuth] only ever decodes tokens it trusts came
/// from its own backend, so it never verifies one.
String _jwtExpiringAt(DateTime expiry) {
  String segment(Map<String, dynamic> payload) =>
      base64Url.encode(utf8.encode(jsonEncode(payload))).replaceAll('=', '');
  final header = segment({'alg': 'none', 'typ': 'JWT'});
  final payload = segment({'exp': expiry.millisecondsSinceEpoch ~/ 1000});
  return '$header.$payload.signature';
}

void main() {
  setUp(Chat360LiveAuth.reset);

  group('login', () {
    test('success persists tokens, email, and the session baseUrl', () async {
      final store = _FakeSecureStore();
      final auth = Chat360LiveAuth(
        baseUrl: 'https://app.chat360.io',
        httpClient: _mockClient({
          'POST /api/auth/wesite-login-user': _ok({
            'access': 'access-1',
            'refresh': 'refresh-1',
            'user_email': 'agent@chat360.io',
          }),
        }),
        storage: store,
      );
      await auth.login(email: 'agent@chat360.io', password: 'secret');

      expect(auth.tokens?.accessToken, 'access-1');
      expect(auth.tokens?.refreshToken, 'refresh-1');
      expect(store.data['chat360_access_token'], 'access-1');
      expect(store.data['chat360_email'], 'agent@chat360.io');
      expect(
        store.data['chat360_session_base_url'],
        'https://app.chat360.io',
      );
    });

    test('failure throws and leaves no session', () async {
      final auth = Chat360LiveAuth(
        httpClient: _mockClient({
          'POST /api/auth/wesite-login-user': _fail(401),
        }),
        storage: _FakeSecureStore(),
      );

      await expectLater(
        () => auth.login(email: 'agent@chat360.io', password: 'wrong'),
        throwsA(isA<Chat360LiveAuthException>()),
      );
      expect(auth.tokens, isNull);
    });

    test(
      'while already logged in as someone else ends that session against '
      "its OWN baseUrl and email, even if it wasn't the caller's default",
      () async {
        final log = <_Recorded>[];
        final client = _mockClient({
          'POST /api/auth/wesite-login-user': _ok({
            'access': 'access-b',
            'refresh': 'refresh-b',
            'user_email': 'b@chat360.io',
          }),
          'GET /api/auth/logout': _ok({}),
          'DELETE /api/mobile/notify': _ok({}),
        }, log: log);
        final auth = Chat360LiveAuth.withTokens(
          const Chat360Tokens(
              accessToken: 'access-a', refreshToken: 'refresh-a'),
          httpClient: client,
          storage: _FakeSecureStore(),
        );
        // withTokens doesn't know an email, so give it one the way
        // _registerFcm's _resolveEmail would — set it directly isn't
        // possible from a test (private), so register FCM via a stubbed
        // auth/user first.
        final logoutBefore = log.length;

        await auth.login(email: 'b@chat360.io', password: 'secret');

        expect(auth.tokens?.accessToken, 'access-b');
        final logoutCall = log
            .skip(logoutBefore)
            .firstWhere((r) => r.url.path == '/api/auth/logout');
        expect(
          logoutCall.url.queryParameters['refresh_token'],
          'refresh-a',
          reason: "must invalidate agent A's refresh token, not B's",
        );
      },
    );

    test('same user re-logging in still tears down the old refresh token',
        () async {
      final log = <_Recorded>[];
      final client = _mockClient({
        'POST /api/auth/wesite-login-user': _ok({
          'access': 'access-2',
          'refresh': 'refresh-2',
          'user_email': 'agent@chat360.io',
        }),
        'GET /api/auth/logout': _ok({}),
      }, log: log);
      final auth = Chat360LiveAuth.withTokens(
        const Chat360Tokens(accessToken: 'access-1', refreshToken: 'refresh-1'),
        httpClient: client,
        storage: _FakeSecureStore(),
      );

      await auth.login(email: 'agent@chat360.io', password: 'secret');

      final logoutCalls = log.where((r) => r.url.path == '/api/auth/logout');
      expect(logoutCalls, isNotEmpty);
      expect(
        logoutCalls.first.url.queryParameters['refresh_token'],
        'refresh-1',
      );
    });
  });

  group('baseUrl persistence across restarts', () {
    test(
      'restoring with the SAME baseUrl the host passes works as before',
      () async {
        final store = _FakeSecureStore();
        final firstRun = Chat360LiveAuth(
          baseUrl: 'https://app.chat360.io',
          httpClient: _mockClient({
            'POST /api/auth/wesite-login-user': _ok({
              'access': 'access-1',
              'refresh': 'refresh-1',
            }),
          }),
          storage: store,
        );
        await firstRun.login(email: 'a@chat360.io', password: 'x');
        Chat360LiveAuth.reset();

        final secondRun = Chat360LiveAuth(
          baseUrl: 'https://app.chat360.io',
          httpClient: _mockClient({}),
          storage: store,
        );
        await pumpEventQueue();

        expect(secondRun.isRestoring, isFalse);
        expect(secondRun.tokens?.accessToken, 'access-1');
        expect(secondRun.baseUrl, 'https://app.chat360.io');
      },
    );

    test(
      'restoring adopts the PERSISTED baseUrl even when the host constructs '
      'with the default — this is the actual "app forgot which URL I used" '
      'bug: a session logged in against dev-oem must not silently start '
      'talking to app.chat360.io after a restart',
      () async {
        final store = _FakeSecureStore();
        final firstRun = Chat360LiveAuth(
          baseUrl: 'https://dev-oem.chat360.io',
          httpClient: _mockClient({
            'POST /api/auth/wesite-login-user': _ok({
              'access': 'access-1',
              'refresh': 'refresh-1',
            }),
          }),
          storage: store,
        );
        await firstRun.login(email: 'a@chat360.io', password: 'x');
        Chat360LiveAuth.reset();

        // Simulates the example app's LoginPage: constructed fresh every
        // launch with its field's default text, having no idea a previous
        // run used a different host.
        final secondRun = Chat360LiveAuth(
          baseUrl: 'https://app.chat360.io',
          httpClient: _mockClient({}),
          storage: store,
        );
        await pumpEventQueue();

        expect(secondRun.tokens?.accessToken, 'access-1');
        expect(
          secondRun.baseUrl,
          'https://dev-oem.chat360.io',
          reason: 'must recover the host the restored session actually '
              'belongs to, not fall back to the constructor default',
        );
      },
    );

    test(
      'an explicit updateBaseUrl() called before restore finishes wins over '
      'the persisted value',
      () async {
        final store = _FakeSecureStore();
        final firstRun = Chat360LiveAuth(
          baseUrl: 'https://dev-oem.chat360.io',
          httpClient: _mockClient({
            'POST /api/auth/wesite-login-user': _ok({
              'access': 'access-1',
              'refresh': 'refresh-1',
            }),
          }),
          storage: store,
        );
        await firstRun.login(email: 'a@chat360.io', password: 'x');
        Chat360LiveAuth.reset();

        final secondRun = Chat360LiveAuth(
          baseUrl: 'https://app.chat360.io',
          httpClient: _mockClient({}),
          storage: store,
        );
        // Synchronous — runs before _restore()'s storage reads resolve.
        secondRun.updateBaseUrl('https://staging.chat360.io');
        await pumpEventQueue();

        expect(
          secondRun.baseUrl,
          'https://staging.chat360.io',
          reason: 'a host that explicitly chose a URL meant it',
        );
      },
    );
  });

  group('updateBaseUrl', () {
    test('same URL is a no-op — no teardown call, session untouched', () async {
      final log = <_Recorded>[];
      final auth = Chat360LiveAuth.withTokens(
        const Chat360Tokens(accessToken: 'a', refreshToken: 'r'),
        baseUrl: 'https://app.chat360.io',
        httpClient: _mockClient({}, log: log),
        storage: _FakeSecureStore(),
      );

      auth.updateBaseUrl('https://app.chat360.io/');
      await pumpEventQueue();

      expect(auth.tokens, isNotNull);
      expect(log, isEmpty);
    });

    test(
      'switching to a different URL ends the session against the OLD host '
      'and clears it locally — the exact bug where cleanup calls were '
      'silently sent to the NEW host using tokens only valid on the old one',
      () async {
        final log = <_Recorded>[];
        final client = _mockClient({
          'GET /api/auth/logout': _ok({}),
        }, log: log);
        final auth = Chat360LiveAuth.withTokens(
          const Chat360Tokens(accessToken: 'a', refreshToken: 'old-refresh'),
          baseUrl: 'https://app.chat360.io',
          httpClient: client,
          storage: _FakeSecureStore(),
        );
        await pumpEventQueue();
        log.clear();

        auth.updateBaseUrl('https://dev-oem.chat360.io');
        await pumpEventQueue();

        expect(auth.tokens, isNull, reason: 'old session must be cleared');
        expect(auth.baseUrl, 'https://dev-oem.chat360.io');
        expect(log, hasLength(1));
        expect(
          log.single.url.host,
          'app.chat360.io',
          reason: 'teardown must hit the host the session actually belongs '
              'to, not the one just switched to',
        );
        expect(log.single.url.queryParameters['refresh_token'], 'old-refresh');
      },
    );

    test('trailing slash and whitespace are normalized before comparing',
        () async {
      final log = <_Recorded>[];
      final auth = Chat360LiveAuth.withTokens(
        const Chat360Tokens(accessToken: 'a', refreshToken: 'r'),
        baseUrl: 'https://app.chat360.io',
        httpClient: _mockClient({}, log: log),
        storage: _FakeSecureStore(),
      );

      auth.updateBaseUrl('  https://app.chat360.io/// ');
      await pumpEventQueue();

      expect(auth.tokens, isNotNull, reason: 'should be treated as unchanged');
      expect(log, isEmpty);
    });
  });

  group('logout', () {
    test('clears session and unregisters the FCM token', () async {
      final log = <_Recorded>[];
      final store = _FakeSecureStore();
      final client = _mockClient({
        'POST /api/auth/wesite-login-user': _ok({
          'access': 'a',
          'refresh': 'r',
        }),
        'GET /api/auth/user': _ok({'email': 'agent@chat360.io'}),
        'POST /api/mobile/notify': _ok({}),
        'GET /api/auth/logout': _ok({}),
        'DELETE /api/mobile/notify': _ok({}),
      }, log: log);
      final auth = Chat360LiveAuth(httpClient: client, storage: store);
      await auth.login(
        email: 'agent@chat360.io',
        password: 'x',
        fcmToken: 'fcm-1',
      );
      expect(store.data['chat360_registered_fcm_token'], 'fcm-1');
      log.clear();

      await auth.logout();

      expect(auth.tokens, isNull);
      expect(store.data.containsKey('chat360_access_token'), isFalse);
      final unregister = log.firstWhere((r) => r.method == 'DELETE');
      expect(unregister.json['fcm_token'], 'fcm-1');
      expect(unregister.json['email'], 'agent@chat360.io');
    });

    test('still clears the local session even if the network calls fail',
        () async {
      final store = _FakeSecureStore();
      final auth = Chat360LiveAuth.withTokens(
        const Chat360Tokens(accessToken: 'a', refreshToken: 'r'),
        httpClient: MockClient((_) async => throw Exception('offline')),
        storage: store,
      );
      await pumpEventQueue();

      await auth.logout();

      expect(auth.tokens, isNull);
      expect(store.data.containsKey('chat360_access_token'), isFalse);
    });

    test('no-op when already signed out', () async {
      final log = <_Recorded>[];
      final auth = Chat360LiveAuth(
        httpClient: _mockClient({}, log: log),
        storage: _FakeSecureStore(),
      );
      await pumpEventQueue();

      await auth.logout();

      expect(log, isEmpty);
    });
  });

  group('refresh', () {
    test('success updates the access token, keeps the refresh token', () async {
      final store = _FakeSecureStore();
      final auth = Chat360LiveAuth.withTokens(
        const Chat360Tokens(accessToken: 'old-access', refreshToken: 'r'),
        httpClient: _mockClient({
          'POST /api/auth/token/refresh/': _ok({'access': 'new-access'}),
        }),
        storage: store,
      );
      await pumpEventQueue();

      final refreshed = await auth.refresh();

      expect(refreshed?.accessToken, 'new-access');
      expect(refreshed?.refreshToken, 'r');
      expect(auth.tokens?.accessToken, 'new-access');
      expect(store.data['chat360_access_token'], 'new-access');
    });

    test('rejected refresh token clears the session', () async {
      final store = _FakeSecureStore();
      final auth = Chat360LiveAuth.withTokens(
        const Chat360Tokens(accessToken: 'a', refreshToken: 'dead'),
        httpClient: _mockClient({
          'POST /api/auth/token/refresh/': _fail(401),
        }),
        storage: store,
      );
      await pumpEventQueue();

      final refreshed = await auth.refresh();

      expect(refreshed, isNull);
      expect(auth.tokens, isNull);
      expect(store.data.containsKey('chat360_access_token'), isFalse);
    });

    test(
      'a network failure returns null but does NOT clear the session — it '
      'might just be a blip, unlike a real rejection',
      () async {
        final auth = Chat360LiveAuth.withTokens(
          const Chat360Tokens(accessToken: 'a', refreshToken: 'r'),
          httpClient: MockClient((_) async => throw Exception('offline')),
          storage: _FakeSecureStore(),
        );
        await pumpEventQueue();

        final refreshed = await auth.refresh();

        expect(refreshed, isNull);
        expect(auth.tokens, isNotNull, reason: 'session must survive a blip');
      },
    );

    test('no session is a no-op', () async {
      final auth = Chat360LiveAuth(
        httpClient: _mockClient({}),
        storage: _FakeSecureStore(),
      );
      await pumpEventQueue();

      expect(await auth.refresh(), isNull);
    });
  });

  group('onSessionExpired', () {
    test('fires when the server rejects the refresh token', () async {
      final auth = Chat360LiveAuth.withTokens(
        const Chat360Tokens(accessToken: 'a', refreshToken: 'dead'),
        httpClient: _mockClient({
          'POST /api/auth/token/refresh/': _fail(401),
        }),
        storage: _FakeSecureStore(),
      );
      await pumpEventQueue();
      var calls = 0;
      auth.onSessionExpired = () => calls++;

      await auth.refresh();

      expect(calls, 1);
    });

    test('does NOT fire on a network blip — the session might still be fine',
        () async {
      final auth = Chat360LiveAuth.withTokens(
        const Chat360Tokens(accessToken: 'a', refreshToken: 'r'),
        httpClient: MockClient((_) async => throw Exception('offline')),
        storage: _FakeSecureStore(),
      );
      await pumpEventQueue();
      var calls = 0;
      auth.onSessionExpired = () => calls++;

      await auth.refresh();

      expect(calls, 0);
    });

    test('does NOT fire on an explicit logout() — the caller already knows',
        () async {
      final auth = Chat360LiveAuth.withTokens(
        const Chat360Tokens(accessToken: 'a', refreshToken: 'r'),
        httpClient: _mockClient({'GET /api/auth/logout': _ok({})}),
        storage: _FakeSecureStore(),
      );
      await pumpEventQueue();
      var calls = 0;
      auth.onSessionExpired = () => calls++;

      await auth.logout();

      expect(calls, 0);
    });

    test(
      'does NOT fire when updateBaseUrl() ends a session — that was the '
      "host's own action too",
      () async {
        final auth = Chat360LiveAuth.withTokens(
          const Chat360Tokens(accessToken: 'a', refreshToken: 'r'),
          baseUrl: 'https://app.chat360.io',
          httpClient: _mockClient({'GET /api/auth/logout': _ok({})}),
          storage: _FakeSecureStore(),
        );
        await pumpEventQueue();
        var calls = 0;
        auth.onSessionExpired = () => calls++;

        auth.updateBaseUrl('https://dev-oem.chat360.io');
        await pumpEventQueue();

        expect(calls, 0);
      },
    );

    test(
      'does NOT fire when a new login replaces the session — the caller '
      'initiated that too',
      () async {
        final auth = Chat360LiveAuth.withTokens(
          const Chat360Tokens(accessToken: 'a', refreshToken: 'r'),
          httpClient: _mockClient({
            'POST /api/auth/wesite-login-user': _ok({
              'access': 'a2',
              'refresh': 'r2',
            }),
            'GET /api/auth/logout': _ok({}),
          }),
          storage: _FakeSecureStore(),
        );
        await pumpEventQueue();
        var calls = 0;
        auth.onSessionExpired = () => calls++;

        await auth.login(email: 'b@chat360.io', password: 'x');

        expect(calls, 0);
      },
    );

    test('via ensureFreshTokens() when the proactive refresh is rejected',
        () async {
      final expired = _jwtExpiringAt(
        DateTime.now().toUtc().subtract(const Duration(minutes: 5)),
      );
      final auth = Chat360LiveAuth.withTokens(
        Chat360Tokens(accessToken: expired, refreshToken: 'dead'),
        httpClient: _mockClient({
          'POST /api/auth/token/refresh/': _fail(401),
        }),
        storage: _FakeSecureStore(),
      );
      await pumpEventQueue();
      var calls = 0;
      auth.onSessionExpired = () => calls++;

      await auth.ensureFreshTokens();

      expect(calls, 1);
    });
  });

  group('ensureFreshTokens', () {
    test('no session returns null without a network call', () async {
      final log = <_Recorded>[];
      final auth = Chat360LiveAuth(
        httpClient: _mockClient({}, log: log),
        storage: _FakeSecureStore(),
      );
      await pumpEventQueue();

      expect(await auth.ensureFreshTokens(), isNull);
      expect(log, isEmpty);
    });

    test(
      'an access token this cannot decode as a JWT is still verified live '
      '(there is no local signal to trust instead) and returned unchanged '
      'when the server accepts it',
      () async {
        final log = <_Recorded>[];
        final auth = Chat360LiveAuth.withTokens(
          const Chat360Tokens(accessToken: 'not-a-jwt', refreshToken: 'r'),
          httpClient: _mockClient({
            'GET /api/auth/user': _ok({'email': 'agent@chat360.io'}),
          }, log: log),
          storage: _FakeSecureStore(),
        );
        await pumpEventQueue();

        final result = await auth.ensureFreshTokens();

        expect(result?.accessToken, 'not-a-jwt');
        expect(log.single.url.path, '/api/auth/user');
      },
    );

    test(
      'a token expiring well beyond the buffer is still verified live — its '
      'own exp claim is a lower bound, not a guarantee the server still '
      'accepts it (e.g. revoked, or superseded by a login elsewhere) — and '
      'returned unchanged when the server accepts it, with no extra refresh '
      'call needed',
      () async {
        final log = <_Recorded>[];
        final token = _jwtExpiringAt(
          DateTime.now().toUtc().add(const Duration(hours: 1)),
        );
        final auth = Chat360LiveAuth.withTokens(
          Chat360Tokens(accessToken: token, refreshToken: 'r'),
          httpClient: _mockClient({
            'GET /api/auth/user': _ok({'email': 'agent@chat360.io'}),
          }, log: log),
          storage: _FakeSecureStore(),
        );
        await pumpEventQueue();

        final result = await auth.ensureFreshTokens();

        expect(result?.accessToken, token);
        expect(log, hasLength(1));
        expect(log.single.url.path, '/api/auth/user');
      },
    );

    test(
      'an unexpired token the server actually rejects (revoked server-side '
      'despite looking fine locally — the exact case a client-side-only '
      'expiry check misses) falls back to refresh()',
      () async {
        final token = _jwtExpiringAt(
          DateTime.now().toUtc().add(const Duration(hours: 1)),
        );
        final auth = Chat360LiveAuth.withTokens(
          Chat360Tokens(accessToken: token, refreshToken: 'r'),
          httpClient: _mockClient({
            'GET /api/auth/user': _fail(401),
            'POST /api/auth/token/refresh/': _ok({'access': 'fresh-access'}),
          }),
          storage: _FakeSecureStore(),
        );
        await pumpEventQueue();

        final result = await auth.ensureFreshTokens();

        expect(result?.accessToken, 'fresh-access');
      },
    );

    test(
      'a network failure verifying is treated as "assume fine," not a '
      'rejection — no refresh call, token returned as-is',
      () async {
        final token = _jwtExpiringAt(
          DateTime.now().toUtc().add(const Duration(hours: 1)),
        );
        final calls = <String>[];
        final auth = Chat360LiveAuth.withTokens(
          Chat360Tokens(accessToken: token, refreshToken: 'r'),
          httpClient: MockClient((request) async {
            calls.add(request.url.path);
            throw Exception('offline');
          }),
          storage: _FakeSecureStore(),
        );
        await pumpEventQueue();

        final result = await auth.ensureFreshTokens();

        expect(result?.accessToken, token);
        expect(calls, ['/api/auth/user']);
      },
    );

    test(
      'a locally-expired token skips verification and goes straight to '
      'refresh — no point confirming what is already certain — and returns '
      'the new tokens',
      () async {
        final log = <_Recorded>[];
        final expired = _jwtExpiringAt(
          DateTime.now().toUtc().subtract(const Duration(minutes: 5)),
        );
        final auth = Chat360LiveAuth.withTokens(
          Chat360Tokens(accessToken: expired, refreshToken: 'r'),
          httpClient: _mockClient({
            'POST /api/auth/token/refresh/': _ok({'access': 'fresh-access'}),
          }, log: log),
          storage: _FakeSecureStore(),
        );
        await pumpEventQueue();

        final result = await auth.ensureFreshTokens();

        expect(result?.accessToken, 'fresh-access');
        expect(auth.tokens?.accessToken, 'fresh-access');
        expect(
          log.map((r) => r.url.path),
          isNot(contains('/api/auth/user')),
        );
      },
    );

    test(
      'a token expiring inside the buffer window also triggers a refresh',
      () async {
        final almostExpired = _jwtExpiringAt(
          DateTime.now().toUtc().add(const Duration(seconds: 10)),
        );
        final auth = Chat360LiveAuth.withTokens(
          Chat360Tokens(accessToken: almostExpired, refreshToken: 'r'),
          httpClient: _mockClient({
            'POST /api/auth/token/refresh/': _ok({'access': 'fresh-access'}),
          }),
          storage: _FakeSecureStore(),
        );
        await pumpEventQueue();

        final result = await auth.ensureFreshTokens(
          buffer: const Duration(seconds: 30),
        );

        expect(result?.accessToken, 'fresh-access');
      },
    );

    test(
        'an expired token whose refresh token is also dead returns null and clears the session',
        () async {
      final expired = _jwtExpiringAt(
        DateTime.now().toUtc().subtract(const Duration(minutes: 5)),
      );
      final auth = Chat360LiveAuth.withTokens(
        Chat360Tokens(accessToken: expired, refreshToken: 'dead'),
        httpClient: _mockClient({
          'POST /api/auth/token/refresh/': _fail(401),
        }),
        storage: _FakeSecureStore(),
      );
      await pumpEventQueue();

      final result = await auth.ensureFreshTokens();

      expect(result, isNull);
      expect(auth.tokens, isNull);
    });
  });

  group('withTokens', () {
    test('replaces the session synchronously, no restoring state', () async {
      final store = _FakeSecureStore();
      final auth = Chat360LiveAuth.withTokens(
        const Chat360Tokens(accessToken: 'a', refreshToken: 'r'),
        storage: store,
        httpClient: _mockClient({}),
      );

      expect(auth.isRestoring, isFalse);
      expect(auth.tokens?.accessToken, 'a');
    });

    test('registers the given FCM token', () async {
      final log = <_Recorded>[];
      Chat360LiveAuth.withTokens(
        const Chat360Tokens(accessToken: 'a', refreshToken: 'r'),
        storage: _FakeSecureStore(),
        httpClient: _mockClient({
          'GET /api/auth/user': _ok({'email': 'agent@chat360.io'}),
          'POST /api/mobile/notify': _ok({}),
        }, log: log),
        fcmToken: 'fcm-token',
      );
      await pumpEventQueue();

      final register = log.firstWhere((r) => r.method == 'POST');
      expect(register.json['fcm_token'], 'fcm-token');
    });
  });

  group('withJWT (Hero OEM SSO)', () {
    Chat360JWTTokens jwt() => const Chat360JWTTokens(
          clientId: 'heromotocorp',
          jwtToken: 'hero-jwt',
          extra: {
            'loginId': 'L1',
            'dealerCode': 'D1',
            'divisionName': 'Main',
          },
        );

    test('success establishes a session and clears lastSsoError', () async {
      final auth = Chat360LiveAuth.withJWT(
        jwt(),
        httpClient: _mockClient({
          'POST /api/campaign-oem/sso/login': _ok({
            'accessToken': 'access-1',
            'refreshToken': 'refresh-1',
          }),
        }),
        storage: _FakeSecureStore(),
      );
      expect(auth.isRestoring, isTrue);
      await pumpEventQueue();

      expect(auth.isRestoring, isFalse);
      expect(auth.tokens?.accessToken, 'access-1');
      expect(auth.lastSsoError, isNull);
    });

    test('failure surfaces the API message via lastSsoError', () async {
      final auth = Chat360LiveAuth.withJWT(
        jwt(),
        httpClient: _mockClient({
          'POST /api/campaign-oem/sso/login': _fail(400, {
            'message': 'Dealer mapping not found for this login.',
          }),
        }),
        storage: _FakeSecureStore(),
      );
      await pumpEventQueue();

      expect(auth.tokens, isNull);
      expect(auth.lastSsoError, 'Dealer mapping not found for this login.');
    });

    test('a network exception surfaces a generic lastSsoError', () async {
      final auth = Chat360LiveAuth.withJWT(
        jwt(),
        httpClient: MockClient((_) async => throw Exception('offline')),
        storage: _FakeSecureStore(),
      );
      await pumpEventQueue();

      expect(auth.tokens, isNull);
      expect(auth.lastSsoError, isNotNull);
      expect(auth.isRestoring, isFalse);
    });
  });

  group('FCM registration is best-effort', () {
    test('a non-200 register response does not throw and is not persisted',
        () async {
      final store = _FakeSecureStore();
      final auth = Chat360LiveAuth(
        httpClient: _mockClient({
          'POST /api/auth/wesite-login-user': _ok({
            'access': 'a',
            'refresh': 'r',
            'user_email': 'agent@chat360.io',
          }),
          'POST /api/mobile/notify': _fail(500),
        }),
        storage: store,
      );

      await auth.login(
        email: 'agent@chat360.io',
        password: 'x',
        fcmToken: 'fcm-1',
      );

      expect(auth.tokens, isNotNull, reason: 'login itself must still succeed');
      expect(store.data.containsKey('chat360_registered_fcm_token'), isFalse);
    });

    test('a network exception registering does not throw', () async {
      final auth = Chat360LiveAuth(
        httpClient: MockClient((request) async {
          if (request.url.path.contains('wesite-login-user')) {
            return _ok(
                {'access': 'a', 'refresh': 'r', 'user_email': 'x@y.com'});
          }
          throw Exception('offline');
        }),
        storage: _FakeSecureStore(),
      );

      await expectLater(
        auth.login(email: 'x@y.com', password: 'x', fcmToken: 'fcm-1'),
        completes,
      );
    });
  });
}
