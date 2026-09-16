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

/// Logs in with real Chat360 credentials via [Chat360LiveAuth.login] — no
/// manual token pasting. The demo has no Firebase project wired up, so it
/// doesn't pass an fcmToken; a real host app would pass the token it gets
/// from its own Firebase setup here.
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.auth});

  final Chat360LiveAuth auth;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _baseUrlController = TextEditingController(
    text: 'https://app.chat360.io',
  );
  bool _isLoggingIn = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _baseUrlController.dispose();
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
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => LiveChatPage(
            auth: widget.auth,
            baseUrl: _baseUrlController.text.trim(),
          ),
        ),
      );
    } on Chat360LiveAuthException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _isLoggingIn = false);
    }
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
              const Text('Log in with real Chat360 agent credentials.'),
              const SizedBox(height: 20),
              TextField(
                controller: _baseUrlController,
                decoration: const InputDecoration(
                  labelText: 'Base URL',
                  border: OutlineInputBorder(),
                ),
              ),
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
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: Colors.red)),
              ],
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _isLoggingIn ? null : _login,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: _isLoggingIn
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Log in'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
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
