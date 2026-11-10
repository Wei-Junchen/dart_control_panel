import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dart_control_panel/core/platform/android_log_share.dart';
import 'package:dart_control_panel/core/platform/app_paths.dart';
import 'package:dart_control_panel/app/flight_logs/flight_log_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('android-share-');
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(AppPaths.channel, null);
    await root.delete(recursive: true);
  });
  test('passes only one session directory and preserves source', () async {
    final csv = await File('${root.path}/1.csv').writeAsString('pitch\n1\n');
    messenger.setMockMethodCallHandler(AppPaths.channel, (call) async {
      expect(call.method, 'shareLogZip');
      expect(call.arguments, {'path': root.absolute.path});
      return {'name': 'single.zip', 'bytes': 123};
    });
    await AndroidLogShare.share(root);
    expect(await csv.readAsString(), 'pitch\n1\n');
  });
  test('native share errors propagate instead of claiming delivery', () async {
    messenger.setMockMethodCallHandler(AppPaths.channel, (_) async {
      throw PlatformException(code: 'ZIP', message: 'storage full');
    });
    await expectLater(
      AndroidLogShare.share(root),
      throwsA(isA<PlatformException>()),
    );
  });
  test('controller serializes packing with other log operations', () async {
    var calls = 0;
    late FlightLogController controller;
    controller = FlightLogController(
      localRoot: root,
      shareLog: (path) async {
        calls++;
        expect(path.path, root.path);
        expect(controller.busy, true);
        await controller.shareLocal(LocalFlightLog(root, {}));
      },
    );
    await controller.shareLocal(LocalFlightLog(root, {}));
    expect(calls, 1);
    expect(controller.busy, false);
    expect(controller.error, isNull);
    expect(controller.status, contains('分享面板'));
    controller.dispose();
  });
}
