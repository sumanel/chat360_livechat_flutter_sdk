import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'chat360_live_auth.dart';

enum _Status {
  /// Working out whether there's a session at all, or the WebView is
  /// mid-flight through the sign-in/settle dance.
  loading,

  /// Settled on `/live-chats` with its chrome hidden — the normal state.
  ready,

  /// [Chat360LiveAuth.tokens] was null when this widget needed them, or became
  /// null while it was showing (e.g. the host called [Chat360LiveAuth.logout]
  /// elsewhere). Nothing wrong happened — there's just no session to show.
  signedOut,

  /// A session existed but didn't work, and [Chat360LiveAuth.refresh] couldn't
  /// recover it either — the refresh token itself was rejected. Only a
  /// real [Chat360LiveAuth.login] fixes this.
  authError,
}

/// Lets a host drive a [Chat360LiveChatSDK] programmatically — jump
/// straight to a conversation, typically from a push notification tap.
/// Attach one to a single [Chat360LiveChatSDK] via its `controller`
/// parameter.
class Chat360LiveChatController {
  _Chat360LiveChatSDKState? _state;

  void _attach(_Chat360LiveChatSDKState state) => _state = state;

  void _detach(_Chat360LiveChatSDKState state) {
    if (identical(_state, state)) _state = null;
  }

  /// Opens the given conversation directly, the same way tapping a chat
  /// row in the inbox would. If the WebView hasn't finished signing in
  /// yet, this is queued and applied automatically once it has.
  Future<void> openConversation(String roomId) async {
    await _state?._openConversation(roomId);
  }

  /// Extracts the room id from a Chat360 push notification's data payload
  /// and opens it — the payload key is `Room_Id`, matching how
  /// `mobile-app` itself reads an incoming notification's data
  /// (`home_screen.dart`'s `onMessageOpenedApp`/`getInitialMessage`
  /// handling). No-ops if the payload doesn't carry one, so it's safe to
  /// call on every notification tap without checking first whether it's a
  /// Chat360 one.
  ///
  /// The host is still responsible for its own `FirebaseMessaging`
  /// listener (`onMessageOpenedApp`, `getInitialMessage`) and for calling
  /// this from it — this class never touches Firebase itself.
  Future<void> handleNotificationTap(Map<String, dynamic> data) async {
    final roomId = data['Room_Id'];
    if (roomId is! String || roomId.isEmpty) return;
    await openConversation(roomId);
  }
}

/// Embeds the Chat360 business console (`app.chat360.io`) as an
/// already-authenticated, mobile-shell view for an agent, locked to just
/// the live-chats inbox and individual conversations.
///
/// It does six things, in order:
/// 1. Reads the current session from [auth] and, once loaded, writes its
///    tokens into `localStorage` under the same keys the web app itself
///    uses (`token` / `refresh-token`), then reloads — the web app has no
///    cookie-based session, so this is what makes it come up already
///    signed in instead of showing its login screen. If the console
///    doesn't accept them (an expired access token), [auth] is asked to
///    refresh silently before trying again; if [auth] has no session at
///    all, or a refresh can't recover one, the WebView never loads —
///    [signedOutBuilder] / [authErrorBuilder] show instead.
/// 2. Hides the sidebar hamburger, the profile/logout menu, the responsive
///    sidebar that otherwise reappears in landscape, and the surrounding
///    desktop chrome (header bar, rounded/bordered card, reserved padding)
///    via CSS, since this shell already provides its own native chrome and
///    that reserved space otherwise just shrinks the usable surface. Hiding
///    rather than click-blocking the hamburger/menu means those elements
///    can't be hit-tested at all, portal or no portal.
/// 3. Rewrites any navigation to `/live-chats/<id>` into `/chats/<id>` —
///    both real page loads and the in-app client-side route change that
///    happens when an agent taps a conversation.
/// 4. Confines the WebView to `/live-chats` and `/chats/<id>` — any other
///    in-app link (client-side or a real page load) bounces back to
///    `/live-chats`; anything that isn't part of the console at all (an
///    external site, a file attachment) is handed to the OS instead of
///    loading inside the shell.
/// 5. Grants microphone/camera access to the page (for voice input and
///    camera attachments) once the OS-level runtime permission has been
///    approved, and wires up the native file picker so attaching a file
///    actually opens one instead of doing nothing.
/// 6. Floors every input's font-size at 16px and forces the viewport meta
///    tag to disable zoom — WebKit auto-zooms in on a focused input under
///    16px and can leave the page stuck zoomed in after the keyboard
///    dismisses.
///
/// A [controller] lets the host jump straight to a conversation from
/// outside — most commonly [Chat360LiveChatController.handleNotificationTap]
/// from its own `FirebaseMessaging.onMessageOpenedApp` /
/// `getInitialMessage` listener, since this widget never touches Firebase
/// itself.
///
/// It also intercepts the host screen's back button/gesture: from an open
/// conversation, back goes to the inbox; from the inbox, back calls
/// [onExitRequested] if given, else pops the nearest [Navigator]. This is
/// tracked internally rather than delegated to the WebView's own
/// back/forward history, since that history also contains this widget's
/// internal redirect churn and can otherwise land outside both allowed
/// routes entirely. There's no back button *visible* unless [headerBuilder]
/// (or the host's own surrounding UI) provides one — the system
/// button/gesture is the only affordance by default.
///
/// [loadingBuilder] covers the WebView until step 2 has actually finished,
/// so the agent never sees the login-page flash or the intermediate
/// redirect the console does on its way to `/live-chats`.
class Chat360LiveChatSDK extends StatefulWidget {
  const Chat360LiveChatSDK({
    super.key,
    required this.auth,
    this.baseUrl = 'https://app.chat360.io',
    this.controller,
    this.loadingBuilder,
    this.signedOutBuilder,
    this.authErrorBuilder,
    this.onExitRequested,
    this.headerBuilder,
    this.onWebResourceError,
  });

  /// Owns the agent's Chat360 session — login, logout, and silent token
  /// refresh. See [Chat360LiveAuth].
  final Chat360LiveAuth auth;

  /// Optional — lets the host call [Chat360LiveChatController.openConversation]
  /// or [Chat360LiveChatController.handleNotificationTap] to jump straight
  /// to a specific conversation, e.g. from a push notification tap.
  final Chat360LiveChatController? controller;

  /// Overridable for staging (e.g. `https://staging.chat360.io`). Must
  /// match the `baseUrl` [auth] was constructed with.
  final String baseUrl;

  /// Shown in place of the WebView until it's actually settled on
  /// `/live-chats` with its chrome hidden. Covers the login-page flash and
  /// the intermediate redirect the console does on its way there, so the
  /// agent never sees that churn. Defaults to a centered spinner on a
  /// plain white background; pass a builder to match the host app's own
  /// loading state instead.
  final WidgetBuilder? loadingBuilder;

  /// Shown instead of the WebView when [auth] has no session — either
  /// there from the start, or because the host called
  /// [Chat360LiveAuth.logout] while this widget was showing. Defaults to a
  /// plain centered message; the host should generally route to its own
  /// login screen rather than relying on this for long.
  final WidgetBuilder? signedOutBuilder;

  /// Shown when a session existed but couldn't be made to work even after
  /// [Chat360LiveAuth.refresh] — the refresh token itself was rejected, so
  /// only a real [Chat360LiveAuth.login] recovers from this. Defaults to a
  /// plain centered message.
  final WidgetBuilder? authErrorBuilder;

  /// Called when the agent presses back (or swipes back on iOS) while
  /// already at the inbox — i.e. there's nothing left *inside* this widget
  /// to go back to. Defaults to `Navigator.of(context).pop()` if not
  /// given, which is right when the host pushed this widget as its own
  /// route (as in `Chat360LiveChat.present`); pass this if the host
  /// embeds it some other way (a tab, say) where popping the navigator
  /// isn't what "leaving" should mean.
  ///
  /// From a conversation, back always goes to the inbox first regardless
  /// of this callback — it only fires at the inbox root.
  final VoidCallback? onExitRequested;

  /// Builds a header shown above the WebView. Called with `isOnChatDetail`
  /// (true when a conversation is open, for a title/back-icon that should
  /// differ by state) and `onBack`, which does exactly what the system
  /// back button/gesture does here: goes from a conversation to the
  /// inbox, or calls [onExitRequested] at the inbox root. Leave null (the
  /// default) for no header — e.g. when the host wraps this in its own
  /// `Scaffold`/`AppBar` instead. See [Chat360LiveChatHeader] for a
  /// ready-made one.
  final Widget Function(
    BuildContext context, {
    required bool isOnChatDetail,
    required VoidCallback onBack,
  })? headerBuilder;

  final void Function(WebResourceError error)? onWebResourceError;

  @override
  State<Chat360LiveChatSDK> createState() =>
      _Chat360LiveChatSDKState();
}

class _Chat360LiveChatSDKState extends State<Chat360LiveChatSDK> {
  static const _liveChatsPath = '/live-chats';
  static final _chatDetailPath = RegExp(r'^/chats/[0-9a-fA-F-]{36}$');

  late final WebViewController _controller;
  _Status _status = _Status.loading;
  // Guards against loading the WebView twice — _onAuthChanged and
  // _startIfSignedIn both start it the moment tokens first appear, and
  // Chat360LiveAuth can notify more than once before that happens (e.g. once
  // when restore() finishes, again if login() is somehow also in flight).
  bool _hasStartedLoadingWebView = false;
  bool _hasInjectedSession = false;
  bool _hasVerifiedLiveChatsRoute = false;
  // Caps the refresh-and-retry in _onPageFinished at one attempt. Without
  // this, a landing that's wrong for a reason other than a stale token
  // (e.g. a genuine permission problem on the account) would refresh and
  // retry forever, since a successful refresh() always resets
  // _hasVerifiedLiveChatsRoute for another attempt.
  bool _hasAttemptedRefresh = false;
  // Tracked ourselves rather than read from the WebView's native
  // back/forward history, since that history also contains our own
  // internal redirect churn (the /login bounce, retry loads) — goBack()
  // through it can land outside the two allowed routes entirely.
  bool _isOnChatDetail = false;
  // Set by openConversation() when it's called before the WebView has
  // finished signing in (e.g. a notification tapped while the app was
  // still cold-starting) — applied once _status reaches ready.
  String? _pendingConversationId;

  @override
  void initState() {
    super.initState();
    widget.auth.addListener(_onAuthChanged);
    widget.controller?._attach(this);
    _controller = WebViewController(
      onPermissionRequest: (request) async {
        // Grants the *web page's* getUserMedia() request — this is
        // separate from, and only meaningful after, the OS-level runtime
        // permission requested in _ensureMediaPermissions below.
        await request.grant();
      },
    )
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _onNavigationRequest,
          onPageFinished: _onPageFinished,
          onWebResourceError: widget.onWebResourceError,
        ),
      )
      ..addJavaScriptChannel(
        'Chat360Nav',
        onMessageReceived: (message) {
          final isOnChatDetail = message.message == 'chat-detail';
          if (mounted && _isOnChatDetail != isOnChatDetail) {
            setState(() => _isOnChatDetail = isOnChatDetail);
          }
        },
      );
    final platformController = _controller.platform;
    if (platformController is AndroidWebViewController) {
      platformController
        ..setMediaPlaybackRequiresUserGesture(false)
        ..setOnShowFileSelector(_onShowFileSelector);
      // iOS's WKWebView shows its own native file/camera/photo picker for
      // <input type="file"> without any extra wiring here.
      if (kDebugMode) {
        // Lets chrome://inspect on a connected desktop Chrome attach to
        // this WebView for real console/network debugging — debug builds
        // only, never release.
        AndroidWebViewController.enableDebugging(true);
      }
    }
    _startIfSignedIn();
  }

  @override
  void didUpdateWidget(covariant Chat360LiveChatSDK oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }
  }

  @override
  void dispose() {
    widget.auth.removeListener(_onAuthChanged);
    widget.controller?._detach(this);
    super.dispose();
  }

  /// Navigates straight to a conversation, the same way tapping a chat row
  /// in the inbox would. Called by [Chat360LiveChatController].
  Future<void> _openConversation(String roomId) async {
    if (_status != _Status.ready) {
      _pendingConversationId = roomId;
      return;
    }
    if (mounted) setState(() => _isOnChatDetail = true);
    await _controller.loadRequest(Uri.parse('${widget.baseUrl}/chats/$roomId'));
  }

  /// Fires on every [Chat360LiveAuth] change — including the moment a
  /// persisted session finishes restoring (or turns out not to exist),
  /// which happens asynchronously and can land well after [initState].
  /// Starts the WebView load the first time tokens actually appear,
  /// however that happened (restore or an explicit [Chat360LiveAuth.login]);
  /// otherwise falls back to signed-out, but only once restoring is
  /// actually done — showing signed-out before that would flash it for an
  /// agent who's still logged in.
  void _onAuthChanged() {
    if (!_hasStartedLoadingWebView && widget.auth.tokens != null) {
      _hasStartedLoadingWebView = true;
      _controller.loadRequest(Uri.parse('${widget.baseUrl}$_liveChatsPath'));
      return;
    }
    if (widget.auth.tokens == null &&
        !widget.auth.isRestoring &&
        _status != _Status.signedOut) {
      setState(() => _status = _Status.signedOut);
    }
  }

  void _startIfSignedIn() {
    if (widget.auth.tokens != null) {
      _hasStartedLoadingWebView = true;
      _controller.loadRequest(Uri.parse('${widget.baseUrl}$_liveChatsPath'));
      return;
    }
    if (!widget.auth.isRestoring) {
      setState(() => _status = _Status.signedOut);
    }
    // Otherwise: still restoring a persisted session — stay in
    // _Status.loading and let _onAuthChanged react once that resolves.
  }

  Future<NavigationDecision> _onNavigationRequest(
    NavigationRequest request,
  ) async {
    if (!request.isMainFrame) {
      // Sub-frame resources the page loads itself — e.g. a reCAPTCHA
      // iframe — aren't the agent navigating anywhere, and blocking them
      // both breaks whatever needed them and pointlessly launches Safari
      // for something that was never a real navigation.
      return NavigationDecision.navigate;
    }

    final rewritten = _rewriteLiveChatUrl(request.url);
    if (rewritten != null) {
      // Prevent this load and issue the corrected one instead — covers a
      // real document navigation (deep link, refresh) landing on
      // /live-chats/<id>. The in-app client-side click case is handled
      // separately in _installClientSideRouteGuard, since react-router
      // navigates via history.pushState and never reaches here.
      await _controller.loadRequest(Uri.parse(rewritten));
      return NavigationDecision.prevent;
    }

    final uri = Uri.tryParse(request.url);
    if (uri != null && _isAllowedPath(uri)) {
      return NavigationDecision.navigate;
    }

    // Anything else reaching here is a real document navigation away from
    // the two allowed routes — a stray in-app link, an external site, or a
    // file attachment (on Android, a download surfaces to this same
    // callback rather than a separate API). None of those should load
    // inside this shell; hand them to the OS instead of just discarding
    // them, so attachments/downloads still work.
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    return NavigationDecision.prevent;
  }

  bool _isAllowedPath(Uri uri) {
    final baseHost = Uri.parse(widget.baseUrl).host;
    if (uri.host != baseHost) return false;
    return uri.path == _liveChatsPath || _chatDetailPath.hasMatch(uri.path);
  }

  /// Turns `.../live-chats/<uuid>` into `.../chats/<uuid>`; returns null for
  /// any URL that doesn't match.
  String? _rewriteLiveChatUrl(String url) {
    final match = RegExp(
      r'^(.*)/live-chats/([0-9a-fA-F-]{36})(/.*)?$',
    ).firstMatch(url);
    if (match == null) return null;
    return '${match.group(1)}/chats/${match.group(2)}${match.group(3) ?? ''}';
  }

  Future<void> _onPageFinished(String url) async {
    if (!_hasInjectedSession) {
      _hasInjectedSession = true;
      await _injectSession();
      // Explicitly (re)load /live-chats rather than calling reload(), which
      // would just reload whatever URL is *currently* loaded. By the time
      // this fires, the app's own auth guard may already have redirected
      // an unauthenticated /live-chats load to /login — reload() would
      // then reload /login, and becoming authenticated there (a public
      // route) sends the app to its own default landing page instead of
      // back to /live-chats. Targeting /live-chats directly sidesteps that
      // regardless of where the race left us.
      await _controller.loadRequest(Uri.parse('${widget.baseUrl}$_liveChatsPath'));
      return;
    }
    if (!_hasVerifiedLiveChatsRoute) {
      _hasVerifiedLiveChatsRoute = true;
      if (Uri.parse(url).path != _liveChatsPath) {
        if (_hasAttemptedRefresh) {
          // Already tried a refresh once this session and still didn't
          // land correctly — this isn't a stale-token problem a second
          // refresh would fix (e.g. a genuine permission issue on the
          // account), so stop instead of refreshing forever.
          if (mounted) setState(() => _status = _Status.authError);
          return;
        }
        _hasAttemptedRefresh = true;
        // Landed somewhere else — most likely the access token was already
        // stale, so injecting it didn't produce a working session. Try a
        // silent refresh before giving up: this is the normal path for an
        // expired access token and needs no host involvement.
        final refreshed = await widget.auth.refresh();
        if (refreshed == null) {
          if (mounted) setState(() => _status = _Status.authError);
          return;
        }
        _hasInjectedSession = false;
        _hasVerifiedLiveChatsRoute = false;
        await _controller.loadRequest(Uri.parse('${widget.baseUrl}$_liveChatsPath'));
        return;
      }
    }
    _isOnChatDetail = _chatDetailPath.hasMatch(Uri.parse(url).path);
    await _hideChromeForEmbed();
    await _disableViewportZoom();
    await _installClientSideRouteGuard();
    await _ensureMediaPermissions();
    if (mounted) {
      setState(() => _status = _Status.ready);
    }
    final pendingConversationId = _pendingConversationId;
    if (pendingConversationId != null) {
      _pendingConversationId = null;
      await _openConversation(pendingConversationId);
    }
  }

  Future<void> _injectSession() {
    final tokens = widget.auth.tokens;
    if (tokens == null) return Future.value();
    return _controller.runJavaScript('''
      localStorage.setItem('token', ${_jsString(tokens.accessToken)});
      localStorage.setItem('refresh-token', ${_jsString(tokens.refreshToken)});
    ''');
  }

  Future<void> _hideChromeForEmbed() {
    return _controller.runJavaScript('''
      (function() {
        var style = document.getElementById('chat360-mobile-shell-style');
        if (!style) {
          style = document.createElement('style');
          style.id = 'chat360-mobile-shell-style';
          document.head.appendChild(style);
        }
        // #chat360__header_comp is the portal target PageHeader renders the
        // profile/logout menu into; .mantine-Burger-root is Mantine v6's
        // stable per-component class for the sidebar hamburger. The Burger
        // is a sibling of #chat360__header_comp inside Topnav's outer
        // Paper, not a descendant, so both rules are needed.
        // .mantine-Navbar-root is the desktop sidebar (Layout.tsx) — it
        // only reappears once the viewport crosses Mantine's "sm" width
        // breakpoint, e.g. rotating the device to landscape, so it needs
        // hiding unconditionally rather than relying on that breakpoint.
        // Beyond hiding those, containers/Layout.tsx also reserves a fixed
        // 56px+ AppShell header slot and wraps the page in a padded,
        // rounded, bordered Paper card — all designed for a desktop chrome
        // this shell already provides natively, so they're stripped too
        // rather than left as dead space. Scoped to .mantine-AppShell-main
        // so it can't touch an unrelated Paper rendered elsewhere (e.g. a
        // portaled dropdown).
        //
        // The single-conversation view (IndividualChat, /chats/:id) adds
        // its own ~12px left/right padding on the Chatbox's root Box
        // (IndividualChat's `classes.chatbox`, Chatbox/index.tsx:947) via
        // an emotion-generated class with no stable name — unlike the
        // rules above, this one reaches it structurally through its known
        // Mantine ancestor chain (Paper > Flex > Box) rather than a class
        // name, so it's more likely to break if that structure changes.
        // WebKit auto-zooms the page when a focused input's font-size is
        // under 16px, and can leave it stuck zoomed in after the keyboard
        // dismisses — this floors every input/textarea/contenteditable at
        // 16px so that never triggers, on top of the meta viewport fix in
        // _disableViewportZoom.
        style.textContent =
          '#chat360__header_comp, .mantine-Burger-root, .mantine-Navbar-root { display: none !important; }' +
          '.mantine-Header-root { display: none !important; height: 0 !important; min-height: 0 !important; }' +
          '.mantine-AppShell-main { padding: 0 !important; }' +
          '.mantine-AppShell-main .mantine-Paper-root { border: none !important; box-shadow: none !important; border-radius: 0 !important; }' +
          '.mantine-AppShell-main .mantine-Paper-root > .mantine-Flex-root > .mantine-Box-root { padding-left: 0 !important; padding-right: 0 !important; }' +
          'input, textarea, [contenteditable="true"] { font-size: 16px !important; }';
      })();
    ''');
  }

  /// Forces the viewport meta tag to disable pinch/auto zoom. Without this,
  /// WKWebView auto-zooms in whenever an input with a sub-16px font gets
  /// focus (the input font-size fix above should already prevent that) and
  /// can leave the page stuck zoomed in after the keyboard dismisses. This
  /// is the belt to that rule's suspenders, and the actual fix if some
  /// input still slips through at a smaller size.
  Future<void> _disableViewportZoom() {
    return _controller.runJavaScript('''
      (function() {
        var meta = document.querySelector('meta[name="viewport"]');
        if (!meta) {
          meta = document.createElement('meta');
          meta.name = 'viewport';
          document.head.appendChild(meta);
        }
        meta.setAttribute(
          'content',
          'width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no'
        );
      })();
    ''');
  }

  /// react-router navigates client-side (history.pushState) when an agent
  /// taps a chat row or any other in-app link, so no real page load happens
  /// and [_onNavigationRequest] never fires for it. This patches pushState
  /// so any such navigation is corrected in place, without a full reload:
  /// `/live-chats/<id>` becomes `/chats/<id>`, and anything other than
  /// `/live-chats` or `/chats/<id>` bounces back to `/live-chats`. It also
  /// reports the resulting page to the `Chat360Nav` JavaScript channel
  /// (registered in initState) every time it settles, which is how
  /// [_isOnChatDetail] stays accurate for a tap that never triggers
  /// [_onPageFinished] at all.
  ///
  /// This relies on react-router's history listening for native `popstate`
  /// events, which is how back/forward navigation reaches it — dispatching
  /// one synthetically is a common way to nudge a router from outside its
  /// bundle, but it hasn't been verified against this app's router version.
  /// Verify a tap on a chat row actually lands on /chats/<id> before
  /// shipping; if it doesn't, this needs a different signal (e.g. the
  /// console adding a small postMessage hook) instead of this patch.
  Future<void> _installClientSideRouteGuard() {
    return _controller.runJavaScript('''
      (function() {
        if (window.__chat360RouteGuardInstalled) return;
        window.__chat360RouteGuardInstalled = true;

        var notify = function(path) {
          var isChatDetail = /^\\/chats\\/[0-9a-fA-F-]{36}\$/.test(path);
          if (window.Chat360Nav) {
            window.Chat360Nav.postMessage(isChatDetail ? 'chat-detail' : 'live-chats');
          }
        };

        var replaceWith = function(path) {
          window.history.replaceState(window.history.state, '', path + window.location.search);
          window.dispatchEvent(new PopStateEvent('popstate', { state: window.history.state }));
        };

        var fix = function() {
          var path = window.location.pathname;
          var liveChatDetail = path.match(/^\\/live-chats\\/([0-9a-fA-F-]{36})\$/);
          if (liveChatDetail) {
            replaceWith('/chats/' + liveChatDetail[1]);
            return;
          }
          var isChatDetail = /^\\/chats\\/[0-9a-fA-F-]{36}\$/.test(path);
          var isLiveChatsRoot = path === '/live-chats';
          if (!isChatDetail && !isLiveChatsRoot) {
            replaceWith('/live-chats');
            return;
          }
          notify(path);
        };

        var originalPushState = window.history.pushState;
        window.history.pushState = function() {
          originalPushState.apply(this, arguments);
          fix();
        };
        window.addEventListener('popstate', fix);
        fix();
      })();
    ''');
  }

  /// Requests the OS-level microphone (and, on Android, camera) runtime
  /// permission so the grant() in setOnPlatformPermissionRequest above
  /// actually has something to grant — the web page's getUserMedia() will
  /// silently fail if the app itself was never given the permission.
  ///
  /// The host app must declare these in its own AndroidManifest.xml
  /// (`RECORD_AUDIO`, `CAMERA`) and Info.plist
  /// (`NSMicrophoneUsageDescription`, `NSCameraUsageDescription`) — a Dart
  /// package can't add those on a consuming app's behalf.
  Future<void> _ensureMediaPermissions() async {
    await [Permission.microphone, Permission.camera].request();
  }

  Future<List<String>> _onShowFileSelector(FileSelectorParams params) async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: params.mode == FileSelectorMode.openMultiple,
      type: FileType.any,
      withReadStream: false,
    );
    final paths = result?.paths.whereType<String>() ?? const <String>[];
    return paths.map((path) => Uri.file(path).toString()).toList();
  }

  String _jsString(String value) {
    final escaped = value.replaceAll('\\', '\\\\').replaceAll("'", "\\'");
    return "'$escaped'";
  }

  /// Handles "back", from wherever it came from — the system button/
  /// gesture (via [_onPopInvoked]) or a tap on [Chat360LiveChatSDK.headerBuilder]'s
  /// own back icon. From an open conversation, goes to the inbox; at the
  /// inbox itself, calls [Chat360LiveChatSDK.onExitRequested] if given,
  /// else pops the nearest [Navigator].
  ///
  /// This deliberately doesn't use the WebView's own `canGoBack()`/
  /// `goBack()` — its native history also contains this widget's internal
  /// redirect churn (the /login bounce, retry loads), so going back through
  /// it can land outside the two allowed routes entirely (e.g. back at
  /// `app.chat360.io`'s bare domain) instead of either of the two places an
  /// agent can actually be. [_isOnChatDetail] is this widget's own
  /// tracking of which of the two allowed pages is showing, so "back" only
  /// ever goes to one of those two places, never anywhere the console's own
  /// history happens to contain.
  Future<void> _handleBack() async {
    if (_isOnChatDetail) {
      setState(() => _isOnChatDetail = false);
      await _controller.loadRequest(Uri.parse('${widget.baseUrl}$_liveChatsPath'));
      return;
    }
    if (widget.onExitRequested != null) {
      widget.onExitRequested!();
    } else if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _onPopInvoked(bool didPop, dynamic result) async {
    if (didPop) return;
    await _handleBack();
  }

  Widget _buildMessage(String message) {
    return ColoredBox(
      color: Colors.white,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(message, textAlign: TextAlign.center),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_status == _Status.signedOut) {
      return widget.signedOutBuilder?.call(context) ??
          _buildMessage('Not signed in.');
    }
    if (_status == _Status.authError) {
      return widget.authErrorBuilder?.call(context) ??
          _buildMessage('Your session has expired. Please sign in again.');
    }
    final content = PopScope(
      canPop: false,
      onPopInvokedWithResult: _onPopInvoked,
      child: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_status != _Status.ready)
            Positioned.fill(
              child: widget.loadingBuilder?.call(context) ??
                  const ColoredBox(
                    color: Colors.white,
                    child: Center(child: CircularProgressIndicator()),
                  ),
            ),
        ],
      ),
    );
    final header = widget.headerBuilder;
    if (header == null) return content;
    return Column(
      children: [
        header(context, isOnChatDetail: _isOnChatDetail, onBack: _handleBack),
        Expanded(child: content),
      ],
    );
  }
}

/// A ready-made header for [Chat360LiveChatSDK.headerBuilder] — a back
/// button plus a title that can differ between the inbox and an open
/// conversation:
///
/// ```dart
/// Chat360LiveChatSDK(
///   auth: auth,
///   headerBuilder: (context, {required isOnChatDetail, required onBack}) =>
///       Chat360LiveChatHeader(isOnChatDetail: isOnChatDetail, onBack: onBack),
/// )
/// ```
///
/// Use this directly for a plain, working header, or as a reference for
/// writing a fully custom one via `headerBuilder` — the only contract
/// that matters is calling `onBack` from whatever back affordance the
/// header shows.
class Chat360LiveChatHeader extends StatelessWidget
    implements PreferredSizeWidget {
  const Chat360LiveChatHeader({
    super.key,
    required this.isOnChatDetail,
    required this.onBack,
    this.inboxTitle = 'Live chat',
    this.conversationTitle = 'Conversation',
    this.backgroundColor,
    this.foregroundColor,
  });

  /// Whether a conversation is currently open — swaps [conversationTitle]
  /// in for [inboxTitle] when true.
  final bool isOnChatDetail;

  /// Call when the back icon is tapped.
  final VoidCallback onBack;

  final String inboxTitle;
  final String conversationTitle;
  final Color? backgroundColor;
  final Color? foregroundColor;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      backgroundColor: backgroundColor,
      foregroundColor: foregroundColor,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: onBack,
        tooltip: 'Back',
      ),
      title: Text(isOnChatDetail ? conversationTitle : inboxTitle),
    );
  }
}
