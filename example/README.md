# chat360_livechat_sdk example

A minimal runnable app showing the whole integration: a real login screen
(`Chat360LiveAuth.login`) followed by the embedded live-chat console
(`Chat360LiveChatSDK`), with a logout button.

## Running it

```bash
flutter pub get
flutter run
```

Log in with real Chat360 agent credentials — this hits the actual
`auth/wesite-login-user` endpoint. See the package [README](../README.md)
for what each piece (`Chat360LiveAuth`, `Chat360LiveChatSDK`,
`Chat360LiveChatController`) does.
