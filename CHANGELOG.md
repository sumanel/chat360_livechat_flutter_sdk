## 0.0.5

- **Fixed**: a session's `baseUrl` is now persisted and restored with it
  (`Chat360LiveAuth.baseUrl`) — previously, restoring a session on a later
  app launch always used whichever `baseUrl` the host happened to construct
  with that run, silently sending a session logged in against e.g.
  `dev-oem.chat360.io` to `app.chat360.io` (or whatever default) after a
  restart. A restored session's own origin now wins automatically, unless
  the host explicitly calls `updateBaseUrl()` first.
- **Added**: `Chat360LiveAuth.updateBaseUrl(String)` — the supported way to
  change the console origin on an already-constructed singleton (e.g. a
  host switching between staging/prod at runtime). Since a session belongs
  to exactly one origin, calling this while a *different* origin's session
  is active best-effort ends that session (against the origin it actually
  belongs to, not the new one) before adopting the new origin.
- **Added**: `Chat360LiveAuth.onSessionExpired` — a settable callback that
  fires specifically when the agent was signed out on Chat360's own side
  (a revoked/rejected refresh token — an admin force-logout, a session
  killed elsewhere, etc.) rather than by the host calling `logout()` itself.
  Lets a host react outside whatever screen `Chat360LiveChatSDK` happens to
  be showing — e.g. navigating back to its own login screen.
- **Added**: `Chat360LiveAuth.ensureFreshTokens()` — proactively verifies
  the session works (checking the access token's own `exp` claim, then a
  live `auth/user` call if that alone isn't conclusive) before
  `Chat360LiveChatSDK` ever loads the WebView, instead of only finding out
  reactively after a page load. Closes a real gap: the web console's own
  client-side routing can silently swap in its login view without a full
  page navigation, which the old reactive check couldn't always detect.
- **Fixed**: `Chat360LiveAuth.refresh()` no longer treats a network failure
  the same as the refresh token being rejected — a connectivity blip no
  longer wipes an otherwise-valid session.
- **Fixed**: logging in as a different agent (or a different session
  entirely, via `updateBaseUrl`) while one is already active now correctly
  tears down the *old* session against the origin and tokens it actually
  belongs to, even after the origin has changed — previously the teardown
  call could be sent to the new origin using tokens only ever valid on the
  old one.
- `Chat360LiveChatSDK.baseUrl` removed — it's read from `auth.baseUrl` now,
  so the WebView and every API call are guaranteed to agree on which
  origin a session belongs to. Pass `Chat360LiveAuth(baseUrl: ...)` (or
  `updateBaseUrl`) instead.
- Testability: introduced `Chat360SecureStore`, a small interface
  `Chat360LiveAuth` now stores its session through instead of the concrete
  `FlutterSecureStorage` — the `storage:` constructor parameter's type
  changed accordingly (only ever meant for test injection). Added a full
  unit test suite (`test/chat360_live_auth_test.dart`) covering login,
  logout, refresh, session-switching, baseUrl persistence/mismatch, and
  `onSessionExpired`.
- `Chat360LiveChatController.openConversation`/`handleNotificationTap` now
  queue correctly even if called before a `controller` is attached to a
  `Chat360LiveChatSDK` at all (not just before it's finished signing in).

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
