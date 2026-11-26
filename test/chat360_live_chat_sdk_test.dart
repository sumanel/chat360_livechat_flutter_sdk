import 'dart:convert';

import 'package:chat360_livechat_sdk/chat360_livechat_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

/// Records what the widget asks the WebView to do.
class _FakeWebView extends WebViewPlatform {
  final loaded = <String>[];
  final scripts = <String>[];
  late _FakeDelegate delegate;

  @override
  PlatformWebViewController createPlatformWebViewController(
          PlatformWebViewControllerCreationParams params) =>
      _FakeController(params, this);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
          PlatformNavigationDelegateCreationParams params) =>
      delegate = _FakeDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
          PlatformWebViewWidgetCreationParams params) =>
      _FakeWidget(params);
}

class _FakeController extends PlatformWebViewController {
  _FakeController(super.params, this.log) : super.implementation();
  final _FakeWebView log;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}
  @override
  Future<void> setPlatformNavigationDelegate(
      PlatformNavigationDelegate handler) async {}
  @override
  Future<void> addJavaScriptChannel(
      JavaScriptChannelParams javaScriptChannelParams) async {}
  @override
  Future<void> setOnPlatformPermissionRequest(
      void Function(PlatformWebViewPermissionRequest request)
          onPermissionRequest) async {}
  @override
  Future<void> loadRequest(LoadRequestParams params) async =>
      log.loaded.add(params.uri.toString());
  @override
  Future<void> runJavaScript(String javaScript) async =>
      log.scripts.add(javaScript);
}

class _FakeDelegate extends PlatformNavigationDelegate {
  _FakeDelegate(super.params) : super.implementation();
  late void Function(String) pageFinished;

  @override
  Future<void> setOnNavigationRequest(
      NavigationRequestCallback onNavigationRequest) async {}
  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async =>
      pageFinished = onPageFinished;
  @override
  Future<void> setOnWebResourceError(
      WebResourceErrorCallback onWebResourceError) async {}
}

class _FakeWidget extends PlatformWebViewWidget {
  _FakeWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

class _MemoryStore implements Chat360SecureStore {
  final data = <String, String>{};
  @override
  Future<String?> read({required String key}) async => data[key];
  @override
  Future<void> write({required String key, required String value}) async =>
      data[key] = value;
  @override
  Future<void> delete({required String key}) async => data.remove(key);
}

void main() {
  const inbox = 'https://app.chat360.io/live-chats';
  late _FakeWebView webView;
  late int issued;

  setUp(() {
    Chat360LiveAuth.reset();
    WebViewPlatform.instance = webView = _FakeWebView();
    issued = 0;
  });

  Chat360JWTTokens jwt(String loginId) => Chat360JWTTokens(
      clientId: 'heromotocorp', jwtToken: 'jwt', extra: {'loginId': loginId});

  final client = MockClient((request) async {
    if (request.url.path.endsWith('sso/login')) {
      issued++;
      return http.Response(
          jsonEncode({
            'accessToken': 'access-$issued',
            'refreshToken': 'refresh-$issued',
          }),
          200);
    }
    return http.Response('{}', 200);
  });

  Future<Chat360LiveAuth> showSignedIn(WidgetTester tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('flutter.baseflow.com/permissions/methods'),
      (_) async => <int, int>{},
    );
    final auth = Chat360LiveAuth.withJWT(jwt('L1'),
        httpClient: client, storage: _MemoryStore());
    await tester.pumpWidget(MaterialApp(home: Chat360LiveChatSDK(auth: auth)));
    await tester.pump();
    return auth;
  }

  String injection() => webView.scripts
      .lastWhere((s) => s.contains("localStorage.setItem('token'"));

  testWidgets('injection clears storage owned by a different agent first',
      (tester) async {
    await showSignedIn(tester);
    webView.delegate.pageFinished(inbox);
    await tester.pump();

    final script = injection();
    expect(script, contains('sso:heromotocorp/L1'));
    expect(script.indexOf('localStorage.clear()'),
        lessThan(script.indexOf("localStorage.setItem('token'")));
  });

  testWidgets('switching agents reloads the WebView for the new session',
      (tester) async {
    await showSignedIn(tester);
    webView.delegate.pageFinished(inbox);
    await tester.pump();
    webView.loaded.clear();
    webView.scripts.clear();

    Chat360LiveAuth.withJWT(jwt('L2'));
    await tester.pump();
    await tester.pump();

    expect(webView.loaded, contains(inbox));
    webView.delegate.pageFinished(inbox);
    await tester.pump();
    expect(injection(), contains("'access-2'"));
    expect(injection(), contains('sso:heromotocorp/L2'));
  });

  testWidgets('logout clears web storage and unloads the console',
      (tester) async {
    final auth = await showSignedIn(tester);
    webView.delegate.pageFinished(inbox);
    await tester.pump();
    webView.loaded.clear();
    webView.scripts.clear();

    await tester.runAsync(auth.logout);
    await tester.pump();

    expect(webView.scripts.join(), contains('localStorage.clear()'));
    expect(webView.scripts.join(), contains('sessionStorage.clear()'));
    expect(webView.loaded, ['about:blank']);
    expect(find.text('Not signed in.'), findsOneWidget);
  });

  testWidgets('signing in again after logout shows the chat again',
      (tester) async {
    final auth = await showSignedIn(tester);
    webView.delegate.pageFinished(inbox);
    await tester.pump();
    await tester.runAsync(auth.logout);
    await tester.pump();
    webView.loaded.clear();

    Chat360LiveAuth.withJWT(jwt('L1'));
    await tester.pump();
    await tester.pump();

    expect(webView.loaded, contains(inbox));
    expect(find.text('Not signed in.'), findsNothing);
  });

  test('a notification without Room_Id is ignored', () async {
    await Chat360LiveChatController().handleNotificationTap({});
  });
}
