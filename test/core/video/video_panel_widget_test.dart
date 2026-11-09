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

  testWidgets('playback dialog shows a seek bar with total duration', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: VideoPlaybackDialog(
          controller: controller,
          url: 'file:///tmp/clip.mp4',
          title: 'clip.mp4',
        ),
      ),
    );
    backend.emitDuration(const Duration(seconds: 90));
    backend.emitPosition(const Duration(seconds: 10));
    backend.emitPlaying();
    await tester.pump();
    await tester.pump();

    expect(find.byType(Slider), findsOneWidget);
    expect(find.text('00:10'), findsOneWidget);
    expect(find.text('01:30'), findsOneWidget);
    expect(find.text('clip.mp4'), findsNothing);
    final sliderY = tester.getCenter(find.byType(Slider)).dy;
    expect(tester.getCenter(find.byTooltip('Pause')).dy, closeTo(sliderY, 1));
    expect(tester.getCenter(find.byTooltip('关闭播放')).dy, closeTo(sliderY, 1));
  });

  testWidgets('file playback hides status and path but retains controls', (
    tester,
  ) async {
    const url = 'file:///private/path/clip.mp4';
    await controller.open(url);
    backend.emitPlaying();
    await tester.pumpWidget(
      MaterialApp(
        home: VideoPlaybackDialog(
          controller: controller,
          url: url,
          title: 'clip.mp4',
        ),
      ),
    );
    await tester.pump();
    expect(find.text(url), findsNothing);
    expect(find.text('playing'), findsNothing);
    expect(find.byTooltip('关闭播放'), findsOneWidget);
    await tester.tap(find.byTooltip('Pause'));
    expect(backend.pauseCalls, 1);
    backend.emitPaused();
    await tester.pump();
    await tester.tap(find.byTooltip('Resume'));
    expect(backend.resumeCalls, 1);
    backend.emitError('failed: $url');
    await tester.pump();
    expect(find.textContaining(url), findsNothing);
    expect(find.textContaining('播放失败'), findsOneWidget);
    await tester.tap(find.byTooltip('重新播放'));
    expect(backend.openCalls, 2);
  });

  testWidgets('seeks while the slider is still being dragged', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showVideoPlaybackDialog(
                  context,
                  controller: controller,
                  url: 'file:///tmp/clip.mp4',
                  title: 'clip.mp4',
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    backend.emitDuration(const Duration(seconds: 90));
    await tester.pump();
    await tester.pump();

    final slider = tester.getRect(find.byType(Slider));
    await tester.tapAt(Offset(slider.right - 40, slider.center.dy));
    await tester.pump();
    expect(backend.seekCalls, 0);
    final gesture = await tester.startGesture(
      Offset(slider.left + 12, slider.center.dy),
    );
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(80, 0));
      await tester.pump();
    }

    expect(backend.seekCalls, greaterThan(1));
    expect(backend.lastSeek!.inSeconds, greaterThan(0));

    await gesture.up();
    await tester.pump();
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
