import 'package:chat360_livechat_sdk/src/chat360_file_selector.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<String> errors;
  late List<(FileType, List<String>?, bool)> picks;
  late List<bool> captures;

  setUp(() {
    errors = [];
    picks = [];
    captures = [];
  });

  Chat360FileSelector selector({
    bool cameraAllowed = true,
    String? captured = '/tmp/photo.jpg',
    List<String> picked = const ['/tmp/a.pdf'],
    Object? captureError,
    Object? Function(FileType type)? pickError,
  }) =>
      Chat360FileSelector(
        requestCamera: () async => cameraAllowed,
        capture: ({required video}) async {
          captures.add(video);
          if (captureError != null) throw captureError;
          return captured;
        },
        pick: ({required type, extensions, required allowMultiple}) async {
          picks.add((type, extensions, allowMultiple));
          final error = pickError?.call(type);
          if (error != null) throw error;
          return picked;
        },
        onError: errors.add,
      );

  Future<List<String>> choose(Chat360FileSelector s,
          {bool capture = false,
          List<String> accept = const [],
          bool multiple = false}) =>
      s.select(
          captureEnabled: capture,
          acceptTypes: accept,
          allowMultiple: multiple);

  test('picked files come back as file URIs', () async {
    expect(await choose(selector(), multiple: true), ['file:///tmp/a.pdf']);
    expect(picks.single.$3, isTrue);
  });

  test('cancelling is not an error', () async {
    expect(await choose(selector(picked: [])), isEmpty);
    expect(await choose(selector(captured: null), capture: true), isEmpty);
    expect(errors, isEmpty);
  });

  test('capture takes a photo, or a video when the page wants one', () async {
    expect(await choose(selector(), capture: true), ['file:///tmp/photo.jpg']);
    await choose(selector(), capture: true, accept: ['video/*']);
    expect(captures, [false, true]);
  });

  test('capture without camera permission is reported', () async {
    final result =
        await choose(selector(cameraAllowed: false), capture: true);

    expect(result, isEmpty);
    expect(captures, isEmpty);
    expect(errors.single, contains('Camera access is off'));
  });

  test('a failing camera is reported, not thrown', () async {
    final s = selector(captureError: PlatformException(code: 'x'));

    expect(await choose(s, capture: true), isEmpty);
    expect(errors.single, contains("Couldn't attach"));
  });

  test('a failing picker is reported, not thrown', () async {
    final s = selector(pickError: (_) => PlatformException(code: 'x'));

    expect(await choose(s), isEmpty);
    expect(errors.single, contains("Couldn't attach"));
  });

  test('a rejected type filter falls back to any file', () async {
    final s = selector(
        pickError: (type) => type == FileType.custom
            ? PlatformException(code: 'unsupported_filter')
            : null);

    expect(await choose(s, accept: ['.heic']), ['file:///tmp/a.pdf']);
    expect(picks.map((p) => p.$1), [FileType.custom, FileType.any]);
    expect(errors, isEmpty);
  });

  Future<(FileType, List<String>?)> filterFor(List<String> accept) async {
    picks.clear();
    await choose(selector(), accept: accept);
    return (picks.single.$1, picks.single.$2);
  }

  test('the picker follows the types the page accepts', () async {
    expect((await filterFor([''])).$1, FileType.any);
    expect((await filterFor(['image/*'])).$1, FileType.image);
    expect((await filterFor(['image/png', 'image/jpeg'])).$1, FileType.image);
    expect((await filterFor(['video/mp4'])).$1, FileType.video);
    expect((await filterFor(['audio/*'])).$1, FileType.audio);

    final documents = await filterFor(['.pdf,.DOCX', 'text/csv']);
    expect(documents.$1, FileType.custom);
    expect(documents.$2, ['pdf', 'docx', 'csv']);
  });

  test('a filter that cannot be expressed shows every file', () async {
    expect((await filterFor(['image/*', '.pdf'])).$1, FileType.any);
    expect((await filterFor(['application/x-unknown'])).$1, FileType.any);
    expect((await filterFor(['*/*'])).$1, FileType.any);
  });
}
