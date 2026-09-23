# Chat360 Live Chat SDK — Integration Guide (Email/Password Login)

This document covers integrating `chat360_livechat_sdk` into a Flutter host app
using **Chat360 email/password login** — the path for an agent who signs in
with the Chat360 credentials your admin portal issued, as opposed to a host
that already has tokens from its own SSO (see `Chat360LiveAuth.withTokens` in
the [README](README.md) for that case).

SDK version: **0.0.1** (tagged [`0.0.1`](https://github.com/sumanel/chat360_livechat_flutter_sdk/releases/tag/0.0.1) in the repo)

> Steps 8–10 (remote sign-out, multiple environments, push notifications)
> describe behavior added since the `0.0.1` tag — see
> [CHANGELOG.md](CHANGELOG.md#unreleased). If you pinned `ref: "0.0.1"` in
> your `pubspec.yaml`, point at a later commit (or `main`) to get them.

---

## 1. Add the dependency

```yaml
# pubspec.yaml
dependencies:
  chat360_livechat_sdk:
    git:
      url: https://github.com/sumanel/chat360_livechat_flutter_sdk.git
      ref: "0.0.1" # pin to the tagged release
  # — or, from a local checkout —
  # chat360_livechat_sdk:
  #   path: ../chat360_livechat_sdk
```

```bash
flutter pub get
```

---

## 2. Minimum OS & SDK support

| | Minimum |
|---|---|
| Android | 9.0 (API 28) |
| iOS | 13.0 |
| Flutter | 3.24.x |
| Dart | 3.5.x (ships with Flutter 3.24.x) |

`chat360_livechat_sdk` is a pure-Dart package with no native `android`/`ios`
folders of its own — the floor is set by the host app's own
`minSdkVersion` / iOS deployment target, and by whichever of those two is
higher across the SDK's plugin dependencies (`webview_flutter`, `file_picker`,
`permission_handler`, `flutter_secure_storage`, `url_launcher`). The highest
floor among them is `minSdkVersion 21` on Android and iOS deployment target
`12.0` — both already below 9.0/13.0, so no dependency blocks supporting
these as your app's minimums.

**Verified working on Flutter 3.24.x** — including a full compiled debug
APK, not just static checks. The SDK's `webview_flutter_android` constraint
originally floored at `^4.4.2`, and every release from 4.3.3 onward requires
Dart ≥3.6.0 — which excluded Flutter 3.24.x (Dart 3.5.x) entirely. That
constraint has been widened to `>=3.16.9 <5.0.0` so pub can resolve to
`webview_flutter_android 4.3.2` (the newest release still compatible with
Dart 3.5.x) on Flutter 3.24.x, while still picking up newer 4.x releases
automatically on newer Flutter. Confirmed against a throwaway host app
depending on the package by path, on **Flutter 3.24.0 exactly** (the stated
floor, Dart 3.5.0) — `flutter pub get`, `flutter analyze`, and
`flutter build apk --debug` all succeeded, producing a real installable
APK. Also re-checked on Flutter 3.24.5 and 3.32.5 with no regressions.

**Three separate host-project template gotchas surfaced along the way** —
none are Dart/Flutter-version issues, all are just what an older
`flutter create` template ships by default versus what the SDK's plugin
dependencies now require:

1. **AGP too old.** `webview_flutter_android`'s AAR requires AGP ≥8.1.1
   (`androidx.webkit:webkit:1.14.0`'s own floor); the 3.24.x template ships
   AGP 7.3.0/8.1.0, which fails with `checkDebugAarMetadata`.
   ```
   // android/settings.gradle(.kts)
   id "com.android.application" version "8.3.0" apply false
   ```
   ```
   # android/gradle/wrapper/gradle-wrapper.properties
   distributionUrl=https\://services.gradle.org/distributions/gradle-8.4-all.zip   # AGP 8.3 needs Gradle >=8.4
   ```
2. **Kotlin Gradle plugin too old.** `webview_flutter_android 4.3.2`'s
   Kotlin sources are compiled against a newer Kotlin metadata version than
   the 3.24.x template's default (1.7.10) understands, failing
   `compileDebugKotlin` with "compiled with an incompatible version of
   Kotlin".
   ```
   // android/settings.gradle(.kts)
   id "org.jetbrains.kotlin.android" version "1.9.24" apply false
   ```
3. **compileSdk/NDK behind what plugins expect** (a non-fatal warning, but
   worth setting explicitly rather than leaving on Flutter's own default):
   ```
   // android/app/build.gradle(.kts)
   android {
       compileSdk = 35
       ndkVersion = "25.1.8937393"
   }
   ```

Set your own host app's floor to match:

```kotlin
// android/app/build.gradle.kts
android {
    defaultConfig {
        minSdk = 28 // Android 9.0
    }
}
```

```ruby
# ios/Podfile
platform :ios, '13.0'
```

```
// ios/Runner.xcodeproj — set IPHONEOS_DEPLOYMENT_TARGET to 13.0
// for the Runner target's Debug/Profile/Release build settings
```

---

## 3. What you need from Chat360

| Value | Purpose |
|---|---|
| Agent `email` / `password` | The Chat360 credentials the agent signs in with |
| `appId` | The `app_id` your Chat360 admin created for this SDK integration — scopes FCM push registration to this app instead of the Chat360 inhouse app |
| Base URL | `https://app.chat360.io` (production) |

Contact the Chat360 integration team for `appId` if you don't already have one.

---

## 4. Create the auth singleton

`Chat360LiveAuth` owns the whole agent session (login, logout, silent token
refresh, FCM registration) and is a true singleton — call it from anywhere,
it always returns the same instance:

```dart
import 'package:chat360_livechat_sdk/chat360_livechat_sdk.dart';

final auth = Chat360LiveAuth(
  appId: 'com.partner.app', // your app_id from Chat360
);
```

---

## 5. Log in with email/password

Call `login()` at the same moment your host app's own login succeeds:

```dart
try {
  await auth.login(
    email: agentEmail,
    password: agentPassword,
    fcmToken: myFcmToken, // optional — from your own Firebase setup
  );
} on Chat360LiveAuthException catch (e) {
  // Bad credentials, network error, or unexpected response — show e.message
}
```

- The session persists across app restarts — a `Chat360LiveAuth` created in a
  later run restores the previous session automatically. Restoration is
  async; check `auth.isRestoring` before treating a momentarily-null
  `auth.tokens` as "not logged in" (only matters if you read `auth.tokens`
  directly for your own navigation logic — the widget in step 6 already
  handles this).

---

## 6. Show the widget

```dart
Chat360LiveChatSDK(auth: auth)
```

That's the whole embed. Optional but commonly used:

```dart
Chat360LiveChatSDK(
  auth: auth,
  headerBuilder: (context, {required isOnChatDetail, required onBack}) =>
      Chat360LiveChatHeader(isOnChatDetail: isOnChatDetail, onBack: onBack),
  // If this widget isn't in its own pushed route (e.g. it's a tab):
  onExitRequested: () => myTabController.animateTo(0),
)
```

Add `headerBuilder` if you don't already wrap the widget in your own
`Scaffold`/`AppBar` — otherwise there's no visible back button (system
back gesture still works without it).

---

## 7. Log out

Call `logout()` at the same moment your host app's own logout happens:

```dart
await auth.logout();
```

This unregisters the FCM token (if one was registered), calls
`auth/logout`, and clears the local session regardless of whether the
network calls succeed.

---

## 8. Handle a remote sign-out

`auth.tokens` going null tells you *that* the session ended, not *why* —
you already know when it's because you called `logout()` yourself, but an
agent getting signed out on Chat360's own side (admin force-logout,
session revoked or superseded elsewhere) needs you to actively react,
often outside whatever screen shows the widget:

```dart
auth.onSessionExpired = () {
  navigatorKey.currentState?.popUntil((route) => route.isFirst);
  showSnackBar('You were signed out of Chat360.');
};
```

Fires only for that case — never from your own `logout()`,
`updateBaseUrl`, or a new `login`/`withJWT`/`withTokens` call replacing
the session (all things you initiated yourself).

---

## 9. Multiple environments (staging / production)

A session belongs to exactly the `baseUrl` it was created under — that's
persisted and restored with it automatically, even if a later run
constructs `Chat360LiveAuth` with a different default. To point an
already-constructed singleton at a different origin at runtime (e.g. a
staging URL read from your own settings screen), call `updateBaseUrl`
rather than trying to reconstruct `Chat360LiveAuth`:

```dart
auth.updateBaseUrl('https://staging.chat360.io');
```

If a different origin's session is currently active, this best-effort
ends it first — a no-op if the origin given is already in effect.

---

## 10. Push notifications

This SDK never touches Firebase — `login()`/`withTokens()`/`withJWT()`
just take an `fcmToken` string to register via `mobile/notify`. You own
getting that token and wiring delivery:

1. **Android** — apply the `com.google.gms.google-services` Gradle plugin,
   add your project's `google-services.json` to `android/app/`, and set
   `minSdk` to at least 23.
2. **iOS** — add `GoogleService-Info.plist` to the Xcode project's "Copy
   Bundle Resources" build phase (not just the filesystem), call
   `FirebaseApp.configure()` in `AppDelegate.swift` before
   `GeneratedPluginRegistrant.register`, enable the Push Notifications and
   Background Modes (remote notification) capabilities (needs a
   `Runner.entitlements` with `aps-environment`, wired via
   `CODE_SIGN_ENTITLEMENTS`), and raise `IPHONEOS_DEPLOYMENT_TARGET` to at
   least 15.0.
3. Fetch the token after requesting notification permission and pass it
   as `fcmToken` to `login()`/`withJWT()`/`withTokens()`.
4. Wire delivery to a conversation via `Chat360LiveChatController`:
   ```dart
   final chatController = Chat360LiveChatController();
   Chat360LiveChatSDK(auth: auth, controller: chatController)

   FirebaseMessaging.onMessageOpenedApp.listen((message) {
     chatController.handleNotificationTap(message.data);
   });
   FirebaseMessaging.instance.getInitialMessage().then((message) {
     if (message != null) chatController.handleNotificationTap(message.data);
   });
   ```
   `handleNotificationTap` reads the payload's `Room_Id` and no-ops if
   it's absent, so it's safe to call on every tap.

All of the above is implemented and verified (real device build, real
APNs sandbox, real login against a live environment) in the
[example app](example/lib/main.dart) — copy its `android/`/`ios/` config
and `main.dart` wiring rather than starting from scratch.

---

## 11. Required platform permissions (voice, camera, file uploads)

The SDK can't add these to your app on its own — declare them yourself:

**Android** (`android/app/src/main/AndroidManifest.xml`):
```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />
<uses-permission android:name="android.permission.CAMERA" />
```

**iOS** (`ios/Runner/Info.plist`):
```xml
<key>NSMicrophoneUsageDescription</key>
<string>Used for voice input in live chat conversations.</string>
<key>NSCameraUsageDescription</key>
<string>Used to attach photos in live chat conversations.</string>
```

Without `RECORD_AUDIO`/`CAMERA` the permission prompt is simply denied (iOS
crashes immediately without the Info.plist entries). `MODIFY_AUDIO_SETTINGS`
is easy to miss — it's silent (no dialog), but without it voice recording
fails on Android with no visible error.

---

## 12. Full worked example

```dart
import 'package:flutter/material.dart';
import 'package:chat360_livechat_sdk/chat360_livechat_sdk.dart';

class LiveChatScreen extends StatefulWidget {
  const LiveChatScreen({super.key});

  @override
  State<LiveChatScreen> createState() => _LiveChatScreenState();
}

class _LiveChatScreenState extends State<LiveChatScreen> {
  final auth = Chat360LiveAuth(appId: 'com.partner.app');
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  String? error;
  bool loggingIn = false;

  Future<void> _login() async {
    setState(() => loggingIn = true);
    try {
      await auth.login(
        email: emailController.text,
        password: passwordController.text,
      );
    } on Chat360LiveAuthException catch (e) {
      setState(() => error = e.message);
    } finally {
      setState(() => loggingIn = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: auth,
      builder: (context, _) {
        if (auth.tokens == null && !auth.isRestoring) {
          return Scaffold(
            appBar: AppBar(title: const Text('Sign in')),
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  TextField(
                    controller: emailController,
                    decoration: const InputDecoration(labelText: 'Email'),
                  ),
                  TextField(
                    controller: passwordController,
                    decoration: const InputDecoration(labelText: 'Password'),
                    obscureText: true,
                  ),
                  const SizedBox(height: 16),
                  if (error != null) Text(error!, style: const TextStyle(color: Colors.red)),
                  ElevatedButton(
                    onPressed: loggingIn ? null : _login,
                    child: Text(loggingIn ? 'Signing in…' : 'Sign in'),
                  ),
                ],
              ),
            ),
          );
        }

        return Scaffold(
          appBar: AppBar(
            title: const Text('Live chat'),
            actions: [
              IconButton(
                icon: const Icon(Icons.logout),
                onPressed: () => auth.logout(),
              ),
            ],
          ),
          body: Chat360LiveChatSDK(auth: auth),
        );
      },
    );
  }
}
```

See the [example app](example) for a complete runnable version.

---

## 13. Reference

- Full README (session persistence, remote sign-out, multiple
  environments, push notifications, notification deep-linking, session
  states, known limitations): [README.md](README.md)
- Auth implementation: [`lib/src/chat360_live_auth.dart`](lib/src/chat360_live_auth.dart)
- Widget implementation: [`lib/src/chat360_live_chat_sdk.dart`](lib/src/chat360_live_chat_sdk.dart)
- Unit tests (a working reference for every documented behavior above —
  login/logout/refresh, session-switching, baseUrl persistence/mismatch,
  `onSessionExpired`): [`test/chat360_live_auth_test.dart`](test/chat360_live_auth_test.dart)

## 14. Contact

For `appId` and production base URL, contact the Chat360 integration team.
