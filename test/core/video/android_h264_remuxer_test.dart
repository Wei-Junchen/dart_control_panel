import 'dart:io';
import 'package:dart_control_panel/core/platform/app_paths.dart';
import 'package:dart_control_panel/core/video/android_h264_remuxer.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File raw;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('dart_android_remux_');
    raw = await File(
      '${directory.path}/1.h264',
    ).writeAsBytes([0, 0, 0, 1, 103]);
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(AppPaths.channel, null);
    await directory.delete(recursive: true);
  });
  test(
    'passes exact FPS and verifies native output without changing source',
    () async {
      final bytes = await raw.readAsBytes();
      messenger.setMockMethodCallHandler(AppPaths.channel, (call) async {
        expect(call.method, 'remuxH264');
        expect(call.arguments, {'path': raw.path, 'fps': 79.5});
        final output = await File(
          '${directory.path}/1.mp4',
        ).writeAsBytes([1, 2, 3]);
        return {'path': await output.resolveSymbolicLinks(), 'frames': 10};
      });
      expect(
        (await AndroidH264Remuxer.convert(raw, 79.5)).path,
        '${directory.path}/1.mp4',
      );
      expect(await raw.readAsBytes(), bytes);
    },
  );
  test('refuses invalid FPS before invoking Android', () async {
    var called = false;
    messenger.setMockMethodCallHandler(AppPaths.channel, (_) async {
      called = true;
      return {};
    });
    for (final fps in [double.nan, double.infinity, 0.0, 1001.0]) {
      await expectLater(
        AndroidH264Remuxer.convert(raw, fps),
        throwsArgumentError,
      );
    }
    expect(called, isFalse);
  });
  test(
    'missing/empty or unexpected output is not reported as success',
    () async {
      messenger.setMockMethodCallHandler(
        AppPaths.channel,
        (_) async => {'path': '${directory.path}/1.mp4'},
      );
      await expectLater(AndroidH264Remuxer.convert(raw, 80), throwsStateError);
      await File('${directory.path}/1.mp4').writeAsBytes([]);
      await expectLater(AndroidH264Remuxer.convert(raw, 80), throwsStateError);
      messenger.setMockMethodCallHandler(
        AppPaths.channel,
        (_) async => {'path': '/wrong.mp4'},
      );
      await expectLater(AndroidH264Remuxer.convert(raw, 80), throwsStateError);
    },
  );
  test('native failures propagate while source remains intact', () async {
    messenger.setMockMethodCallHandler(
      AppPaths.channel,
      (_) async =>
          throw PlatformException(code: 'REMUX', message: 'missing SPS'),
    );
    await expectLater(
      AndroidH264Remuxer.convert(raw, 80),
      throwsA(isA<PlatformException>()),
    );
    expect(await raw.exists(), isTrue);
  });
}
