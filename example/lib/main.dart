import 'package:chat360_livechat_sdk/chat360_livechat_sdk.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

/// Runs for a data-only/background push while the app isn't in the
/// foreground. Must be a top-level (or static) function — the platform
/// calls it in its own isolate. This demo has nothing to do with the
/// payload here (a tap is what routes to a conversation, handled by
/// [Chat360LiveChatController.handleNotificationTap] via
/// [FirebaseMessaging.onMessageOpenedApp]/`getInitialMessage` instead), but
/// a host that wants to react to a *silent* push (e.g. to update a badge)
/// would do that here.
@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundHandler);
  runApp(const DemoApp());
}

class DemoApp extends StatefulWidget {
  const DemoApp({super.key});

  @override
  State<DemoApp> createState() => _DemoAppState();
}

class _DemoAppState extends State<DemoApp> {
  final _auth = Chat360LiveAuth();

  @override
  void dispose() {
    _auth.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Chat360LiveChatSDK demo',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF1F4A3F)),
      home: LoginPage(auth: _auth),
    );
  }
}

enum _LoginMode { password, heroSso }

// A known Hero test account's SSO extra fields, for the "Fill test user"
// button below — saves retyping them on every test run. The JWT itself
// isn't here: it's short-lived and comes from Hero's own backend, so it
// has to be pasted in fresh each time rather than hardcoded.
const _testHeroLoginId = 'HARSHIT10251';
const _testHeroDealerCode = '10251';
const _testHeroDivisionName = '10251 - Main S/R';

/// Logs in either with real Chat360 credentials via [Chat360LiveAuth.login],
/// or via the Hero mobile OEM SSO exchange
/// (`POST /api/campaign-oem/sso/login`) via [Chat360LiveAuth.withJWT] —
/// both take the token this page fetches from its own `firebase_messaging`
/// setup ([_fetchFcmToken]) and register it for push via `mobile/notify`.
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.auth});

  final Chat360LiveAuth auth;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  _LoginMode _mode = _LoginMode.password;

  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _baseUrlController = TextEditingController(
    text: 'https://app.chat360.io',
  );

  // Hero mobile SSO — clientId is fixed to "heromotocorp" in v0. These
  // fields are what the OEM app already holds from Hero's own login.
  final _jwtController = TextEditingController();
  final _loginIdController = TextEditingController();
  final _dealerCodeController = TextEditingController();
  final _divisionNameController = TextEditingController();

  bool _isLoggingIn = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Asks the OS for notification permission up front so the token below
    // is actually deliverable to (iOS requires this before APNs will hand
    // out a token at all; Android 13+ needs it for the notification to
    // show, though FCM delivery itself doesn't depend on it there).
    FirebaseMessaging.instance.requestPermission();
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _baseUrlController.dispose();
    _jwtController.dispose();
    _loginIdController.dispose();
    _dealerCodeController.dispose();
    _divisionNameController.dispose();
    super.dispose();
  }

  /// The token this device's `firebase_messaging` setup gets from APNs
  /// (iOS) / FCM (Android). Best-effort — a device without a valid
  /// provisioning profile / entitlement, or one that denied notification
  /// permission, won't have one, and login should proceed without push
  /// registration rather than fail because of it.
  Future<String?> _fetchFcmToken() async {
    try {
      return await FirebaseMessaging.instance.getToken();
    } catch (e) {
      debugPrint('Could not fetch FCM token: $e');
      return null;
    }
  }

  Future<void> _login() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = 'Enter both email and password.');
      return;
    }
    setState(() {
      _isLoggingIn = true;
      _error = null;
    });
    try {
      final fcmToken = await _fetchFcmToken();
      await widget.auth.login(
        email: email,
        password: password,
        fcmToken: fcmToken,
      );
      if (!mounted) return;
      _openLiveChat(widget.auth);
    } on Chat360LiveAuthException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _isLoggingIn = false);
    }
  }

  /// [Chat360LiveAuth.withJWT] can't be awaited directly — the exchange
  /// happens in the background and the singleton it returns is the same
  /// [widget.auth] this page already holds. This listens for
  /// [Chat360LiveAuth.isRestoring] to clear, then checks whether the
  /// exchange actually produced a session ([Chat360LiveAuth.tokens]) or
  /// failed ([Chat360LiveAuth.lastSsoError]).
  Future<void> _loginWithHeroSso() async {
    final jwtToken = _jwtController.text.trim();
    final loginId = _loginIdController.text.trim();
    final dealerCode = _dealerCodeController.text.trim();
    final divisionName = _divisionNameController.text.trim();
    if (jwtToken.isEmpty ||
        loginId.isEmpty ||
        dealerCode.isEmpty ||
        divisionName.isEmpty) {
      setState(() => _error = 'Fill in the Hero JWT and all extra fields.');
      return;
    }
    setState(() {
      _isLoggingIn = true;
      _error = null;
    });

    final fcmToken = await _fetchFcmToken();
    final auth = Chat360LiveAuth.withJWT(
      Chat360JWTTokens(
        clientId: 'heromotocorp',
        jwtToken: jwtToken,
        extra: {
          'loginId': loginId,
          'dealerCode': dealerCode,
          'divisionName': divisionName,
        },
      ),
      fcmToken: fcmToken,
    );

    void onAuthChanged() {
      if (auth.isRestoring) return;
      auth.removeListener(onAuthChanged);
      if (!mounted) return;
      setState(() => _isLoggingIn = false);
      if (auth.tokens != null) {
        _openLiveChat(auth);
      } else {
        setState(() => _error = auth.lastSsoError ?? 'Hero SSO login failed.');
      }
    }

    auth.addListener(onAuthChanged);
    // Covers the (unlikely) case where the exchange already finished by
    // the time the listener above is attached.
    if (!auth.isRestoring) onAuthChanged();
  }

  void _openLiveChat(Chat360LiveAuth auth) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LiveChatPage(
          auth: auth,
          baseUrl: _baseUrlController.text.trim(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Chat360LiveChatSDK demo')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<_LoginMode>(
                segments: const [
                  ButtonSegment(
                    value: _LoginMode.password,
                    label: Text('Email & password'),
                  ),
                  ButtonSegment(
                    value: _LoginMode.heroSso,
                    label: Text('Hero SSO'),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: _isLoggingIn
                    ? null
                    : (selection) {
                        setState(() {
                          _mode = selection.first;
                          _error = null;
                        });
                      },
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _baseUrlController,
                decoration: const InputDecoration(
                  labelText: 'Base URL',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              if (_mode == _LoginMode.password)
                ..._passwordFields()
              else
                ..._heroSsoFields(),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: Colors.red)),
              ],
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _isLoggingIn
                    ? null
                    : (_mode == _LoginMode.password
                        ? _login
                        : _loginWithHeroSso),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: _isLoggingIn
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          _mode == _LoginMode.password
                              ? 'Log in'
                              : 'Sign in with Hero SSO',
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _passwordFields() => [
        const Text('Log in with real Chat360 agent credentials.'),
        const SizedBox(height: 12),
        TextField(
          controller: _emailController,
          decoration: const InputDecoration(
            labelText: 'Email',
            border: OutlineInputBorder(),
          ),
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _passwordController,
          decoration: const InputDecoration(
            labelText: 'Password',
            border: OutlineInputBorder(),
          ),
          obscureText: true,
          onSubmitted: (_) => _login(),
        ),
      ];

  /// Fills in the known test account's loginId/dealerCode/divisionName —
  /// everything except the JWT itself, which has to come from Hero's
  /// backend fresh each time (see [_testHeroLoginId] and friends).
  void _fillTestHeroFields() {
    _loginIdController.text = _testHeroLoginId;
    _dealerCodeController.text = _testHeroDealerCode;
    _divisionNameController.text = _testHeroDivisionName;
  }

  List<Widget> _heroSsoFields() => [
        const Text(
          'Exchanges a Hero mobile JWT for a Chat360 session '
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _fillTestHeroFields,
            icon: const Icon(Icons.bolt),
            label: const Text('Fill test user (loginId/dealerCode/division)'),
          ),
        ),
        TextField(
          controller: _jwtController,
          decoration: const InputDecoration(
            labelText: 'Hero JWT (token)',
            border: OutlineInputBorder(),
          ),
          minLines: 1,
          maxLines: 4,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _loginIdController,
          decoration: const InputDecoration(
            labelText: 'extra.loginId — e.g. HOST12169',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _dealerCodeController,
          decoration: const InputDecoration(
            labelText: 'extra.dealerCode — e.g. 12169',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _divisionNameController,
          decoration: const InputDecoration(
            labelText: 'extra.divisionName — e.g. 12169 - Main S/R',
            border: OutlineInputBorder(),
          ),
        ),
      ];
}

class LiveChatPage extends StatefulWidget {
  const LiveChatPage({super.key, required this.auth, required this.baseUrl});

  final Chat360LiveAuth auth;
  final String baseUrl;

  @override
  State<LiveChatPage> createState() => _LiveChatPageState();
}

class _LiveChatPageState extends State<LiveChatPage> {
  // Drives Chat360LiveChatSDK from outside — attached to both the real
  // FirebaseMessaging listeners below and the "Simulate push tap" button,
  // so a tap routes to the right conversation the same way regardless of
  // whether it came from an actual push or the manual test affordance.
  final _controller = Chat360LiveChatController();

  @override
  void initState() {
    super.initState();
    // Cold start: the app was launched *by* tapping a notification, so
    // there's no onMessageOpenedApp event to catch — the tapped message is
    // handed back here instead.
    FirebaseMessaging.instance.getInitialMessage().then((message) {
      if (message != null) _controller.handleNotificationTap(message.data);
    });
    // Warm start: the app was already running in the background.
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      _controller.handleNotificationTap(message.data);
    });
  }

  Future<void> _logout(BuildContext context) async {
    await widget.auth.logout();
    if (context.mounted) Navigator.of(context).pop();
  }

  /// Stands in for a tapped push notification, for testing without having
  /// to actually send one through a Chat360 conversation. Prompts for a
  /// room id and feeds it through the exact same controller call the
  /// FirebaseMessaging listeners above make for a real tap.
  Future<void> _simulatePushTap(BuildContext context) async {
    final roomIdController = TextEditingController();
    final roomId = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Simulate push notification tap'),
        content: TextField(
          controller: roomIdController,
          decoration: const InputDecoration(
            labelText: 'Room_Id',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(roomIdController.text.trim()),
            child: const Text('Open'),
          ),
        ],
      ),
    );
    roomIdController.dispose();
    if (roomId == null || roomId.isEmpty) return;
    // Same shape FCM delivers a Chat360 notification's data payload in.
    await _controller.handleNotificationTap({'Room_Id': roomId});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Chat360LiveChatSDK(
        auth: widget.auth,
        baseUrl: widget.baseUrl.isEmpty
            ? 'https://app.chat360.io'
            : widget.baseUrl,
        controller: _controller,
        signedOutBuilder: (context) => const Center(
          child: Text('Signed out.'),
        ),
        authErrorBuilder: (context) => const Center(
          child: Text('Session expired — log in again.'),
        ),
        // Back from the inbox pops this page (the default), same as
        // tapping the header's own back icon would.
        headerBuilder: (context, {required isOnChatDetail, required onBack}) =>
            Chat360LiveChatHeader(
          isOnChatDetail: isOnChatDetail,
          onBack: onBack,
        ),
        onWebResourceError: (error) {
          debugPrint('WebView error: ${error.description} (${error.errorCode})');
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _simulatePushTap(context),
        tooltip: 'Simulate a push notification tap',
        icon: const Icon(Icons.notifications_active),
        label: const Text('Simulate push tap'),
      ),
      // floatingActionButton: FloatingActionButton.small(
      //   onPressed: () => _logout(context),
      //   tooltip: 'Log out',
      //   child: const Icon(Icons.logout),
      // ),
    );
  }
}
