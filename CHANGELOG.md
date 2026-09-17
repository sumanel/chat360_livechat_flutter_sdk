## 0.0.1

Initial release.

- `Chat360LiveAuth` — singleton session manager: login, logout, silent
  token refresh, and FCM registration against Chat360's own endpoints.
  Persists the session via `flutter_secure_storage` and restores it on
  app restart. Takes an optional `appId`, sent as `app_id` on every FCM
  register/unregister call so a partner integration's tokens are stored
  on its own row instead of the Chat360 inhouse app's.
- `Chat360LiveChatSDK` — embeds the Chat360 business live-chat console as
  an already-authenticated, mobile-shell WebView locked to the live-chats
  inbox and individual conversations, with native chrome (hamburger,
  profile menu, desktop padding) stripped out.
- `Chat360LiveChatController` — opens a specific conversation
  programmatically, including routing a push notification tap straight to
  the right conversation.
- `webview_flutter_android` floor widened from `^4.4.2` to `>=3.16.9 <5.0.0`
  so the package resolves on Flutter 3.24.x (Dart 3.5.x) — every
  `webview_flutter_android` release from 4.3.3 onward requires Dart
  >=3.6.0, which had silently excluded Flutter 3.24.x entirely.
