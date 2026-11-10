import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dart_control_panel/core/board/session/board_session.dart';
import 'package:dart_control_panel/core/video/video_controller.dart';
import 'package:dart_control_panel/features/ground_test/config_controls.dart';
import 'package:dart_control_panel/features/ground_test/ground_test_screen.dart';
import '../helpers/fake_video_backend.dart';

void main() {
  final port = int.tryParse(
    Platform.environment['DART_CONFIG_TEST_PORT'] ?? '',
  );
  testWidgets(
    'real daemon schema drives Ground controls, hot apply and full upload',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final session = BoardSession(host: '127.0.0.1', port: port!);
      await tester.runAsync(session.connect);
      final video = VideoController(backend: FakeVideoBackend());
      await tester.pumpWidget(
        MaterialApp(
          home: GroundTestScreen(session: session, videoController: video),
        ),
      );
      Future<void> until(bool Function() condition) async {
        for (var i = 0; i < 150; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
          await tester.pump(const Duration(milliseconds: 30));
          if (condition()) return;
        }
        fail(
          'async board/UI operation did not settle: ${session.statusMessage}',
        );
      }

      final controls = find.byType(ConfigControls, skipOffstage: false);
      await until(() => tester.widget<ConfigControls>(controls).draft.loaded);
      final draft = tester.widget<ConfigControls>(controls).draft;
      expect(draft.schema, isNotNull);
      await tester.tap(find.text('Controls'));
      await tester.pump();
      final cx = find.byKey(const ValueKey('config-control.cx'));
      await tester.ensureVisible(cx);
      await tester.enterText(cx, '90.5');
      await tester.pump();
      // Normal state polls do not replace a dirty config document.
      session.updateState(session.state!);
      await tester.pump();
      expect(draft.at('control.cx'), 90.5);
      final before = session.state!.workerPid;
      final live = find.byKey(const ValueKey('apply-config-runtime'));
      await tester.ensureVisible(live);
      await tester.tap(live);
      await tester.pump();
      await until(() => !draft.busy && !draft.dirty);
      expect(
        session.state!.workerPid,
        before,
        reason: 'hot apply must not restart worker',
      );
      final stored = await tester.runAsync(
        () => session.repository!.getConfig(),
      );
      expect(stored!['control']['cx'], 90.5);
      final gop = find.byKey(const ValueKey('config-record.gop'));
      await tester.ensureVisible(gop);
      await tester.enterText(gop, '31');
      await tester.pump();
      expect(
        tester.widget<FilledButton>(live).onPressed,
        isNull,
        reason: 'non-runtime changes need full upload',
      );
      final upload = find.byKey(const ValueKey('apply-config-controls'));
      await tester.ensureVisible(upload);
      await tester.tap(upload);
      await tester.pump();
      expect(find.text('Upload complete configuration?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('confirm-json-upload')));
      await tester.pump();
      await until(() => !draft.busy && !draft.dirty);
      expect(draft.at('record.gop'), 31);
      expect(session.state!.workerPid, isNot(before));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(session.disconnect);
    },
    // Invoked explicitly by the cross-language integration harness.
    skip: port == null,
  );
}
