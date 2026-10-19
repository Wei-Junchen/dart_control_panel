import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dart_control_panel/core/video/video_controller.dart';
import 'package:dart_control_panel/core/board/models/daemon_state.dart';
import 'package:dart_control_panel/core/video/video_backend.dart';
import 'package:dart_control_panel/core/video/video_panel.dart';

import '../../helpers/fake_video_backend.dart';

DaemonState _state() {
  final raw = File(
    'test/fixtures/payloads/state_envelope_full.json',
  ).readAsStringSync();
  return DaemonState.fromEnvelope(jsonDecode(raw) as Map<String, dynamic>);
}

void main() {
  late FakeVideoBackend backend;
  late VideoController controller;

  setUp(() {
    backend = FakeVideoBackend();
    controller = VideoController(backend: backend);
  });

  tearDown(() {
    controller.dispose();
  });

  Future<void> pump(WidgetTester tester, {bool rtspAvailable = true}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VideoPanel(
            controller: controller,
            rtspAvailable: rtspAvailable,
            url: 'rtsp://10.149.242.1:8554/live',
          ),
        ),
      ),
    );
  }

  testWidgets('idle state shows Start preview', (tester) async {
    await pump(tester);
    expect(find.text('stopped'), findsOneWidget);
    expect(find.text('Start preview'), findsOneWidget);
    expect(find.text('Preview stopped'), findsOneWidget);
  });

  testWidgets('Start preview opens the url', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Start preview'));
    await tester.pump();
    expect(backend.lastUrl, 'rtsp://10.149.242.1:8554/live');
    expect(controller.status, VideoStatus.connecting);
  });

  testWidgets('playing/buffering/error statuses are visible', (tester) async {
    await pump(tester);
    await controller.open('rtsp://10.149.242.1:8554/live');
    backend.emitBuffering();
    await tester.pump();
    expect(find.text('buffering'), findsOneWidget);

    backend.emitPlaying();
    await tester.pump();
    expect(find.text('playing'), findsOneWidget);
  });

  testWidgets('stream error shows message and Reconnect button', (
    tester,
  ) async {
    await pump(tester);
    await controller.open('rtsp://10.149.242.1:8554/live');
    backend.emitPlaying();
    backend.emitError('stream dropped');
    await tester.pump();

    expect(find.text('stream error'), findsOneWidget);
    expect(find.text('stream dropped'), findsOneWidget);
    expect(find.text('Reconnect player'), findsOneWidget);

    await tester.tap(find.text('Reconnect player'));
    await tester.pump();
    expect(backend.openCalls, 2);
  });

  testWidgets('rtsp unavailable replaces the preview button', (tester) async {
    await pump(tester, rtspAvailable: false);
    // panel still shows surface placeholder, but no Start button enabled;
    // the screen shows RtspUnavailable instead of the panel in that case —
    // here we assert the panel simply refuses to start.
    final button = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Start preview'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('live preview offers jump-to-live instead of pause', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VideoPanel(
            controller: controller,
            rtspAvailable: true,
            url: 'rtsp://10.149.242.1:8554/live',
            liveStream: true,
          ),
        ),
      ),
    );
    await controller.open('rtsp://10.149.242.1:8554/live');
    backend.emitPlaying();
    await tester.pump();

    expect(find.text('live · no buffer'), findsOneWidget);
    expect(find.byTooltip('Pause'), findsNothing);
    expect(find.byTooltip('丢弃旧帧并回到实时画面'), findsOneWidget);
    await tester.tap(find.byTooltip('丢弃旧帧并回到实时画面'));
    await tester.pump();
    expect(backend.closeCalls, 1);
    expect(backend.openCalls, 2);
  });

  test('rtspAvailableFor requires both feature and stream flags', () {
    expect(rtspAvailableFor(_state()), isTrue); // fixture has both on
    final workerOff = DaemonState.fromEnvelope({
      'payload': {
        'features': {'rtsp': true, 'uart_enabled': true},
        'worker': {
          'stream': {'rtsp_enabled': false},
        },
      },
    });
    expect(rtspAvailableFor(workerOff), isFalse);
    expect(rtspUrl('10.149.242.1'), 'rtsp://10.149.242.1:8554/live');
    expect(
      rtspUrl('10.149.242.1', port: 9000),
      'rtsp://10.149.242.1:9000/live',
    );
  });
}
