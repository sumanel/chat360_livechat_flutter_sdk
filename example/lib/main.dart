import 'package:chat360_livechat_sdk/chat360_livechat_sdk.dart';
import 'package:flutter/material.dart';

void main() {
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

/// Logs in either with real Chat360 credentials via [Chat360LiveAuth.login],
/// or via the Hero mobile OEM SSO exchange
/// (`POST /api/campaign-oem/sso/login`) via [Chat360LiveAuth.withJWT]. The
/// demo has no Firebase project wired up, so it doesn't pass an fcmToken; a
/// real host app would pass the token it gets from its own Firebase setup
/// to either path.
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
      await widget.auth.login(email: email, password: password);
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

  List<Widget> _heroSsoFields() => [
        const Text(
          'Exchanges a Hero mobile JWT for a Chat360 session '
        ),
        const SizedBox(height: 12),
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

class LiveChatPage extends StatelessWidget {
  const LiveChatPage({super.key, required this.auth, required this.baseUrl});

  final Chat360LiveAuth auth;
  final String baseUrl;

  Future<void> _logout(BuildContext context) async {
    await auth.logout();
    if (context.mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Chat360LiveChatSDK(
        auth: auth,
        baseUrl: baseUrl.isEmpty ? 'https://app.chat360.io' : baseUrl,
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
      // floatingActionButton: FloatingActionButton.small(
      //   onPressed: () => _logout(context),
      //   tooltip: 'Log out',
      //   child: const Icon(Icons.logout),
      // ),
    );
  }
}
