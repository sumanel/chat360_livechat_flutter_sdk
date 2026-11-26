import 'dart:convert';

import 'package:chat360_livechat_sdk/chat360_livechat_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

/// Records what the widget asks the WebView to do.
class _FakeWebView extends WebViewPlatform {
  final loaded = <String>[];
  final scripts = <String>[];
  late _FakeDelegate delegate;
  late void Function(PlatformWebViewPermissionRequest) permissionRequest;
  String? currentUrl;

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
          onPermissionRequest) async =>
      log.permissionRequest = onPermissionRequest;
  @override
  Future<String?> currentUrl() async => log.currentUrl;
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
  late NavigationRequestCallback navigationRequest;

  @override
  Future<void> setOnNavigationRequest(
          NavigationRequestCallback onNavigationRequest) async =>
      navigationRequest = onNavigationRequest;
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

// ignore: must_be_immutable
class _FakePermissionRequest extends PlatformWebViewPermissionRequest {
  _FakePermissionRequest(Set<WebViewPermissionResourceType> types)
      : super(types: types);
  bool? granted;

  @override
  Future<void> grant() async => granted = true;
  @override
  Future<void> deny() async => granted = false;
}

class _FakeLauncher extends UrlLauncherPlatform {
  final launched = <String>[];
  bool result = true;
  Object? error;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    if (error != null) throw error!;
    return result;
  }
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
  late _FakeLauncher launcher;
  late List<int> permissionsAsked;
  late int permissionStatus;
  late List<String> actionErrors;
  const granted = 1;
  const denied = 0;

  setUp(() {
    UrlLauncherPlatform.instance = launcher = _FakeLauncher();
    permissionsAsked = [];
    permissionStatus = granted;
    actionErrors = [];
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

  Future<Chat360LiveAuth> showSignedIn(WidgetTester tester,
      {bool handleErrors = true}) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('flutter.baseflow.com/permissions/methods'),
      (call) async {
        final asked = (call.arguments as List).cast<int>();
        permissionsAsked.addAll(asked);
        return {for (final p in asked) p: permissionStatus};
      },
    );
    final auth = Chat360LiveAuth.withJWT(jwt('L1'),
        httpClient: client, storage: _MemoryStore());
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Chat360LiveChatSDK(
          auth: auth,
          onActionError: handleErrors ? actionErrors.add : null,
        ),
      ),
    ));
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

  const camera = 1;
  const microphone = 7;
  final android = TargetPlatformVariant.only(TargetPlatform.android);
  final ios = TargetPlatformVariant.only(TargetPlatform.iOS);

  Future<_FakePermissionRequest> pageAsksFor(WidgetTester tester,
      Set<WebViewPermissionResourceType> types) async {
    final request = _FakePermissionRequest(types);
    webView.permissionRequest(request);
    await tester.pump();
    return request;
  }

  testWidgets('opening chat does not ask for camera or microphone',
      (tester) async {
    await showSignedIn(tester);
    webView.delegate.pageFinished(inbox);
    await tester.pump();
    webView.delegate.pageFinished(inbox);
    await tester.pump();

    expect(permissionsAsked, isEmpty);
  }, variant: android);

  testWidgets('Android asks only for what the console requests', (tester) async {
    await showSignedIn(tester);
    webView.currentUrl = inbox;

    final request = await pageAsksFor(
        tester, {WebViewPermissionResourceType.microphone});

    expect(permissionsAsked, [microphone]);
    expect(request.granted, isTrue);
    expect(actionErrors, isEmpty);
  }, variant: android);

  testWidgets('Android denies the page when the agent denies the permission',
      (tester) async {
    await showSignedIn(tester);
    webView.currentUrl = inbox;
    permissionStatus = denied;

    final request =
        await pageAsksFor(tester, {WebViewPermissionResourceType.camera});

    expect(permissionsAsked, [camera]);
    expect(request.granted, isFalse);
    expect(actionErrors.single, contains('Camera access is off'));
  }, variant: android);

  testWidgets('a page outside Chat360 never gets camera or microphone',
      (tester) async {
    await showSignedIn(tester);
    for (final url in [
      'https://evil.example/live-chats',
      'http://app.chat360.io/live-chats',
      'about:blank',
      null,
    ]) {
      webView.currentUrl = url;
      final request =
          await pageAsksFor(tester, {WebViewPermissionResourceType.camera});
      expect(request.granted, isFalse, reason: '$url');
    }
    expect(permissionsAsked, isEmpty);
  }, variant: android);

  testWidgets('iOS leaves the system prompt to the WebView', (tester) async {
    await showSignedIn(tester);
    webView.currentUrl = inbox;

    final request = await pageAsksFor(
        tester, {WebViewPermissionResourceType.microphone});

    expect(request.granted, isTrue);
    expect(permissionsAsked, isEmpty);
  }, variant: ios);

  Future<NavigationDecision> navigate(WidgetTester tester, String url) async {
    final decision = await webView.delegate.navigationRequest(
        NavigationRequest(url: url, isMainFrame: true));
    await tester.pump();
    return decision;
  }

  const file = 'https://files.example/report.pdf';

  testWidgets('a document link opens outside the app', (tester) async {
    await showSignedIn(tester);

    expect(await navigate(tester, file), NavigationDecision.prevent);
    expect(launcher.launched, [file]);
    expect(actionErrors, isEmpty);
  });

  testWidgets('a link nothing can open is reported', (tester) async {
    await showSignedIn(tester);
    launcher.result = false;

    expect(await navigate(tester, file), NavigationDecision.prevent);
    expect(actionErrors.single, contains("Couldn't open"));
  });

  testWidgets('a launcher failure is reported, not thrown', (tester) async {
    await showSignedIn(tester);
    launcher.error = PlatformException(code: 'ACTIVITY_NOT_FOUND');

    expect(await navigate(tester, 'blob:https://app.chat360.io/abc'),
        NavigationDecision.prevent);
    expect(actionErrors.single, contains("Couldn't open"));
  });

  testWidgets('without onActionError the agent sees a snackbar',
      (tester) async {
    await showSignedIn(tester, handleErrors: false);
    launcher.result = false;

    await navigate(tester, file);

    expect(find.textContaining("Couldn't open"), findsOneWidget);
  });

  test('a notification without Room_Id is ignored', () async {
    await Chat360LiveChatController().handleNotificationTap({});
  });
}
