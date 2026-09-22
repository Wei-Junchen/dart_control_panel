import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dart_control_panel/controllers/board_session.dart';
import 'package:dart_control_panel/controllers/file_controller.dart';
import 'package:dart_control_panel/controllers/video_controller.dart';
import 'package:dart_control_panel/models/daemon_state.dart';
import 'package:dart_control_panel/screens/files_screen.dart';
import 'package:dart_control_panel/screens/ground_test_screen.dart';
import 'package:dart_control_panel/screens/mode_screen.dart';
import 'package:dart_control_panel/services/board_file_api.dart';
import 'package:dart_control_panel/widgets/video_panel.dart';

import 'helpers/fake_video_backend.dart';

DaemonState _fixtureState({bool rtspOn = true}) {
  final raw = File(
    'test/fixtures/payloads/state_envelope_full.json',
  ).readAsStringSync();
  final envelope = jsonDecode(raw) as Map<String, dynamic>;
  final payload = Map<String, dynamic>.from(envelope['payload'] as Map);
  final features = Map<String, dynamic>.from(payload['features'] as Map)
    ..['rtsp'] = rtspOn;
  payload['features'] = features;
  envelope['payload'] = payload;
  return DaemonState.fromEnvelope(envelope);
}

void main() {
  group('GroundTestScreen', () {
    testWidgets('video + picture config + tuning render side by side wide', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final session = BoardSession();
      session.updateState(_fixtureState());
      final backend = FakeVideoBackend();
      final video = VideoController(backend: backend);

      await tester.pumpWidget(
        MaterialApp(
          home: GroundTestScreen(session: session, videoController: video),
        ),
      );
      await tester.pump();

      expect(find.text('Ground Test'), findsOneWidget);
      expect(find.byType(VideoPanel), findsOneWidget);
      expect(find.text('画面配置'), findsOneWidget);
      expect(find.text('Configuration Studio'), findsOneWidget);
      expect(find.text('default.json'), findsOneWidget);
      expect(find.byKey(const ValueKey('json-config-source')), findsOneWidget);

      final controlsSegment = find.descendant(
        of: find.byKey(const ValueKey('configuration-view-selector')),
        matching: find.text('Controls'),
      );
      await tester.tap(controlsSegment);
      await tester.pump();
      expect(find.text('Detector'), findsOneWidget); // tuning section
      expect(find.text('ISP'), findsOneWidget);
      // Overlay controls live only in the right-hand Display tuning section;
      // the picture column must not expose a second immediate-action copy.
      expect(find.text('overlay'), findsOneWidget);
      expect(find.text('overlay roi'), findsOneWidget);
      video.dispose();
      session.disconnect();
    });

    testWidgets('rtsp off shows the unavailable panel instead of video', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final session = BoardSession();
      session.updateState(_fixtureState(rtspOn: false));
      final backend = FakeVideoBackend();
      final video = VideoController(backend: backend);
      await tester.pumpWidget(
        MaterialApp(
          home: GroundTestScreen(session: session, videoController: video),
        ),
      );
      await tester.pump();
      expect(find.text('RTSP is not enabled on this board'), findsOneWidget);
      expect(find.byType(VideoPanel), findsNothing);
      video.dispose();
      session.disconnect();
    });
  });

  group('ModeScreen', () {
    testWidgets('shows current mode and can request flight', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final session = BoardSession();
      session.updateState(_fixtureState());
      await tester.pumpWidget(MaterialApp(home: ModeScreen(session: session)));
      await tester.pump();

      expect(find.text('Ground 地面'), findsWidgets);
      // cancel the confirm dialog on switching (tap the segment, not the
      // description text which also contains "Flight")
      final flightSegment = find.descendant(
        of: find.byType(SegmentedButton<String>),
        matching: find.text('Flight 空中'),
      );
      expect(flightSegment, findsOneWidget);
      await tester.tap(flightSegment);
      await tester.pumpAndSettle();
      expect(find.textContaining('RTSP 会立即停止'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      session.disconnect();
    });
  });

  group('FilesScreen', () {
    testWidgets('renders remote entries from a fake backend', (tester) async {
      final api = _FakeFileApi();
      final dir = Directory.systemTemp.createTempSync('dart_ctrl_widget_');
      final controller = FileController(
        api: api,
        bookmarksFile: File('${dir.path}/bookmarks.json'),
      );
      await controller.init().then((_) => controller.cd('/recordings'));
      await tester.pumpWidget(
        MaterialApp(
          home: FilesScreen(host: 'board.test', controller: controller),
        ),
      );
      await tester.pump();

      expect(find.textContaining('/recordings'), findsWidgets);
      expect(find.textContaining('flight_1.h264'), findsWidgets);
      expect(find.byIcon(Icons.download), findsWidgets);
      controller.dispose();
      dir.deleteSync(recursive: true);
    });
  });
}

class _FakeFileApi implements BoardFileApi {
  @override
  String get host => 'board.test';
  @override
  int get port => 9002;

  @override
  Future<BoardFileInfo> info() async => const BoardFileInfo(
    hostname: 'dart-test',
    port: 9002,
    readOnly: true,
    range: true,
    available: true,
    roots: ['/logs', '/recordings'],
  );

  @override
  Future<List<RemoteEntry>> list(String path) async => [
    if (path == '/')
      const RemoteEntry(
        name: 'recordings',
        path: '/recordings',
        isDir: true,
        size: 0,
        modifiedMs: 0,
      ),
    if (path == '/recordings') ...[
      const RemoteEntry(
        name: 'flight_1.h264',
        path: '/recordings/flight_1.h264',
        isDir: false,
        size: 1048576,
        modifiedMs: 1788790260000,
      ),
    ],
  ];

  @override
  Future<void> download(String remotePath, String localPath) async {}

  @override
  Uri downloadUri(String remotePath) =>
      Uri.parse('http://board.test:9002/v1/download?path=$remotePath');

  @override
  Future<String> readText(String remotePath, {int maxBytes = 262144}) async =>
      '';

  @override
  void close() {}
}
