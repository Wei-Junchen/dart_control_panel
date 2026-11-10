import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dart_control_panel/core/board/models/daemon_state.dart';
import 'package:dart_control_panel/shared/widgets/board_error_banner.dart';

void main() {
  final captureDir = Platform.environment['DART_WORKER_ERROR_CAPTURE_DIR'];
  if (captureDir != null) {
    testWidgets('real daemon TCP envelope renders production worker failure', (
      tester,
    ) async {
      final response =
          jsonDecode(
                File(
                  '$captureDir/camera_recovery_state.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect(response['ok'], isTrue);
      final state = DaemonState.fromEnvelope(
        Map<String, dynamic>.from(response['payload'] as Map),
      );
      expect(state.state, 'ERROR');
      expect(state.workerError!.exitCode, 69);
      expect(state.workerError!.nativeCode, -123);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: BoardErrorBanner(state: state)),
        ),
      );
      expect(find.textContaining('重建恢复失败'), findsOneWidget);
      await tester.tap(find.byType(ExpansionTile));
      await tester.pumpAndSettle();
      expect(find.textContaining('stage=camera.recovery'), findsOneWidget);
      expect(find.textContaining('0xffffff85'), findsOneWidget);
      expect(find.textContaining('precise failure'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'camera fault is visible without worker state on a narrow screen',
    (tester) async {
      tester.view.physicalSize = const Size(640, 960);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = DaemonState.fromEnvelope({
        'payload': {
          'state': 'ERROR',
          'last_error': 'CAMERA_RECOVERY_EXHAUSTED',
          'worker_error': {
            'code': 'CAMERA_RECOVERY_EXHAUSTED',
            'stage': 'camera.recovery',
            'exit_code': 69,
            'native_code': -123,
            'active': true,
          },
        },
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: BoardErrorBanner(state: state)),
        ),
      );
      expect(find.textContaining('重建恢复失败'), findsOneWidget);
      await tester.tap(find.byType(ExpansionTile));
      await tester.pumpAndSettle();
      expect(find.textContaining('native=-123'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('recovered error is history rather than active alarm', (
    tester,
  ) async {
    final state = DaemonState.fromEnvelope({
      'payload': {
        'worker_error': {
          'code': 'CAMERA_INITIALIZATION_FAILED',
          'active': false,
        },
      },
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: BoardErrorBanner(state: state)),
      ),
    );
    expect(find.textContaining('历史异常（已恢复）'), findsOneWidget);
  });
  testWidgets('legacy last_error still appears', (tester) async {
    final state = DaemonState.fromEnvelope({
      'payload': {'last_error': 'legacy worker exited rc=255'},
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: BoardErrorBanner(state: state)),
      ),
    );
    expect(find.text('legacy worker exited rc=255'), findsOneWidget);
  });
}
