# Chat360LiveChatSDK (`chat360_livechat_sdk`)

A Flutter SDK that embeds the Chat360 business live-chat console
(`app.chat360.io`) inside a host app as an already-authenticated,
stripped-down mobile view — for a host that wants the web console's feature
set (e.g. WhatsApp voice-call handling) without waiting on native parity.

## Installation

This package is intended to be published to pub.dev (open source); until
that's actually done, depend on it directly from its repository or a local
checkout:

```yaml
# pubspec.yaml
dependencies:
  chat360_livechat_sdk:
    git:
      url: https://github.com/<org>/chat360_livechat_sdk.git
  # — or, from a local checkout —
  # chat360_livechat_sdk:
  #   path: ../chat360_livechat_sdk
```

Once it's on pub.dev:

```yaml
dependencies:
  chat360_livechat_sdk: ^0.0.1
```

Then:

```bash
flutter pub get
```

## Quick start

Three calls cover the whole integration — log in, show the widget, log out:

```dart
import 'package:chat360_livechat_sdk/chat360_livechat_sdk.dart';

final auth = Chat360LiveAuth(
  appId: 'com.partner.app', // the app_id your Chat360 admin created for this SDK
); // singleton — same instance from anywhere

// 1. Call at the same moment the host app's own login succeeds.
await auth.login(
  email: agentEmail,
  password: agentPassword,
  fcmToken: myFcmToken, // from the host's own Firebase setup; optional
);

// 2. Show it — full screen, in a tab, wherever the host wants it.
Chat360LiveChatSDK(auth: auth)

// 3. Call at the same moment the host app's own logout happens.
await auth.logout();
```

See the [example app](example) for a complete runnable version, including
a login screen.

## Usage guide

### Authentication

`Chat360LiveAuth` owns the agent's whole Chat360 session — login, logout, and
silent token refresh — and is a true singleton: `Chat360LiveAuth()` returns
the same instance no matter where or how many times it's called, so
there's exactly one Chat360 session in a running app. Call it wherever's
convenient — there's no "create once and thread it through" to get right.

The host never touches a raw access/refresh token directly. Passing
`fcmToken` to `login()` registers it for push right away; `logout()`
unregisters it.

Pass `appId` to `Chat360LiveAuth(...)` — the `app_id` your Chat360 admin
created for this integration — so FCM registration is scoped to this SDK
instead of the Chat360 inhouse app.

If the host already has tokens from elsewhere (its own SSO, say) rather
than a Chat360 email/password, wrap them instead:

```dart
Chat360LiveAuth.withTokens(
  Chat360Tokens(accessToken: ..., refreshToken: ...),
)
```

### Session persistence across app restarts

The session (tokens, email, and which FCM token is currently registered)
is persisted securely and restored automatically when a new
`Chat360LiveAuth` is constructed — an agent stays signed in across a cold
start, and `logout()` can still unregister an FCM token that was
registered in a previous run of the app.

Restoring is async, so there's a brief window right after construction
where `Chat360LiveAuth` doesn't yet know whether a session exists —
`Chat360LiveAuth.isRestoring` is true for that window. `Chat360LiveChatSDK`
already accounts for this itself (it waits for restoring to finish before
ever showing `signedOutBuilder`), but if a host reads `auth.tokens`
directly to decide its own navigation (e.g. "show login screen vs. home
screen" at app startup), check `isRestoring` first rather than treating a
momentarily-null `tokens` as "not logged in".

### Opening a specific conversation (e.g. from a push notification)

Attach a `Chat360LiveChatController` to jump straight to a conversation
from outside the widget — most commonly from the host's own
`FirebaseMessaging` listener, since this package never touches Firebase
itself:

```dart
final chatController = Chat360LiveChatController();

Chat360LiveChatSDK(auth: auth, controller: chatController)

// In the host's own notification handling:
FirebaseMessaging.onMessageOpenedApp.listen((message) {
  chatController.handleNotificationTap(message.data);
});
FirebaseMessaging.instance.getInitialMessage().then((message) {
  if (message != null) chatController.handleNotificationTap(message.data);
});
```

`handleNotificationTap` reads the notification payload's `Room_Id` field
and no-ops if it isn't present, so it's safe to call on every notification
tap without checking first whether it's a Chat360 one. Call
`chatController.openConversation(roomId)` directly if the host already has
the room id some other way. Either call is queued automatically if the
WebView hasn't finished signing in yet.

### Voice, camera & file uploads

The host app must declare these runtime permissions itself — a Dart-only
package can't add them on a consuming app's behalf:

- **Android** (`android/app/src/main/AndroidManifest.xml`):
  ```xml
  <uses-permission android:name="android.permission.RECORD_AUDIO" />
  <uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />
  <uses-permission android:name="android.permission.CAMERA" />
  ```
- **iOS** (`ios/Runner/Info.plist`):
  ```xml
  <key>NSMicrophoneUsageDescription</key>
  <string>Used for voice input in live chat conversations.</string>
  <key>NSCameraUsageDescription</key>
  <string>Used to attach photos in live chat conversations.</string>
  ```

Without `RECORD_AUDIO`/`CAMERA`, the permission request will simply be
denied (or, on iOS, the app will crash immediately). `MODIFY_AUDIO_SETTINGS`
is easy to miss since it's silent (a normal permission, no dialog) — without
it, voice recording fails on Android with no visible error at all.

### Session states

`Chat360LiveChatSDK` shows one of three things, not just loading-vs-ready:

- **`signedOutBuilder`** — `Chat360LiveAuth.tokens` is null, either from
  the start or because the host called `logout()` while this widget was
  showing. The WebView never loads in this state.
- **`authErrorBuilder`** — a session existed but a `refresh()` couldn't
  recover it (the refresh token itself was rejected). Only a real
  `login()` fixes this; there's no automatic retry loop.
- Otherwise, the normal `loadingBuilder` → WebView flow.

### Back navigation and a header

The system back button/gesture already works with no setup: from an open
conversation it returns to the inbox, and from the inbox it pops the
nearest `Navigator` — but there's no *visible* back button unless
something provides one. If the host doesn't wrap this widget in its own
`Scaffold`/`AppBar`, add one via `headerBuilder`:

```dart
Chat360LiveChatSDK(
  auth: auth,
  headerBuilder: (context, {required isOnChatDetail, required onBack}) =>
      Chat360LiveChatHeader(isOnChatDetail: isOnChatDetail, onBack: onBack),
)
```

`Chat360LiveChatHeader` is a ready-made bar with a back icon and a title
that swaps between the inbox and conversation states (customizable via
its `inboxTitle`/`conversationTitle`/color parameters) — or write a fully
custom header with `headerBuilder`; the only thing that matters is
calling the `onBack` you're handed from whatever back affordance it shows.

If the host embeds this somewhere that isn't its own pushed route (a tab,
say), pass `onExitRequested` so "back from the inbox" does the right
thing instead of popping a `Navigator` that isn't there:

```dart
Chat360LiveChatSDK(
  auth: auth,
  onExitRequested: () => myTabController.animateTo(0),
)
```

## Known limitation — blob: downloads

File attachment/download hand-off works for a normal `https://` URL. It
does **not** work for a `blob:` URL (a file the page builds client-side
rather than serving as a network resource) — that needs a JavaScript
bridge to read the blob's contents, which isn't implemented yet. Flagging
it here so it isn't mistaken for a bug when a specific attachment type
doesn't download.

## Not handled here

- **Firebase setup itself** — `Chat360LiveAuth.login()` takes an `fcmToken`
  *string*; it doesn't depend on `firebase_messaging` or initialize
  Firebase. The host owns its own Firebase project and hands over the
  token.

## License

BSD 3-Clause — see [LICENSE](LICENSE).
