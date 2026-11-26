/// Agent-facing messages passed to `Chat360LiveChatSDK.onActionError`.
abstract final class Chat360ActionMessages {
  static const cameraOff =
      'Camera access is off. Allow it in your device settings.';
  static const microphoneOff =
      'Microphone access is off. Allow it in your device settings.';
  static const attachFailed = "Couldn't attach the file.";
  static const openFailed = "Couldn't open this link or file.";
}
