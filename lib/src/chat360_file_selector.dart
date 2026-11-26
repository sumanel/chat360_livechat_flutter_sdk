import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import 'chat360_action_messages.dart';

/// What the file picker should show.
typedef _Filter = ({FileType type, List<String>? extensions});

const _anyFile = (type: FileType.any, extensions: null);

const _extensionsByMimeType = <String, List<String>>{
  'application/pdf': ['pdf'],
  'application/msword': ['doc'],
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document': [
    'docx'
  ],
  'application/vnd.ms-excel': ['xls'],
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': ['xlsx'],
  'application/vnd.ms-powerpoint': ['ppt'],
  'application/vnd.openxmlformats-officedocument.presentationml.presentation': [
    'pptx'
  ],
  'application/zip': ['zip'],
  'text/plain': ['txt'],
  'text/csv': ['csv'],
};

/// Answers Android's file chooser for the console's `<input type="file">`.
/// Never throws: the WebView waits for an answer, so every failure is
/// reported through [onError] and answered with no files.
class Chat360FileSelector {
  Chat360FileSelector({
    required this.requestCamera,
    required this.capture,
    required this.pick,
    required this.onError,
  });

  /// Returns whether the app may use the camera, asking if necessary.
  final Future<bool> Function() requestCamera;

  /// Opens the camera; returns the file's path, or null if cancelled.
  final Future<String?> Function({required bool video}) capture;

  /// Opens the file picker; returns the chosen paths, empty if cancelled.
  final Future<List<String>> Function({
    required FileType type,
    List<String>? extensions,
    required bool allowMultiple,
  }) pick;

  final void Function(String message) onError;

  /// [captureEnabled] means the page wants the camera directly (its input has
  /// a `capture` attribute), which `file_picker` can't do.
  Future<List<String>> select({
    required bool captureEnabled,
    required List<String> acceptTypes,
    required bool allowMultiple,
  }) async {
    final accepted = [
      for (final entry in acceptTypes)
        for (final type in entry.split(','))
          if (type.trim().isNotEmpty) type.trim().toLowerCase(),
    ];
    try {
      final paths = captureEnabled
          ? await _capture(accepted)
          : await _pick(_filterFor(accepted), allowMultiple);
      return [for (final path in paths) Uri.file(path).toString()];
    } catch (e) {
      debugPrint('Chat360LiveChatSDK: could not select a file: $e');
      onError(Chat360ActionMessages.attachFailed);
      return const [];
    }
  }

  Future<List<String>> _capture(List<String> accepted) async {
    if (!await requestCamera()) {
      onError(Chat360ActionMessages.cameraOff);
      return const [];
    }
    final path = await capture(
      video: accepted.any((type) => type.startsWith('video/')),
    );
    return path == null ? const [] : [path];
  }

  Future<List<String>> _pick(_Filter filter, bool allowMultiple) async {
    Future<List<String>> run(_Filter f) => pick(
          type: f.type,
          extensions: f.extensions,
          allowMultiple: allowMultiple,
        );
    if (filter.type != FileType.custom) return run(filter);
    try {
      return await run(filter);
    } catch (e) {
      // Android rejects extensions it has no MIME type for.
      debugPrint('Chat360LiveChatSDK: file type filter rejected: $e');
      return run(_anyFile);
    }
  }

  /// Narrows the picker only when every accepted type can be expressed;
  /// otherwise shows every file rather than hiding one the page would take.
  _Filter _filterFor(List<String> accepted) {
    if (accepted.isEmpty) return _anyFile;
    const media = {
      'image/': FileType.image,
      'video/': FileType.video,
      'audio/': FileType.audio,
    };
    for (final MapEntry(:key, :value) in media.entries) {
      if (accepted.every((type) => type.startsWith(key))) {
        return (type: value, extensions: null);
      }
    }
    final extensions = <String>{};
    for (final type in accepted) {
      final known = type.startsWith('.')
          ? [type.substring(1)]
          : _extensionsByMimeType[type];
      if (known == null) return _anyFile;
      extensions.addAll(known);
    }
    return (type: FileType.custom, extensions: extensions.toList());
  }
}
