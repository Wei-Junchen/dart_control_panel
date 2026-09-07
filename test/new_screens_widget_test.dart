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
import 'package:dart_control_panel/services/board_ssh.dart';
import 'package:dart_control_panel/widgets/video_panel.dart';

import 'helpers/fake_video_backend.dart';

DaemonState _fixtureState({bool rtspOn = true}) {
  final raw = File('test/fixtures/payloads/state_envelope_full.json')
      .readAsStringSync();
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
    testWidgets('video + picture config + tuning render side by side wide',
        (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final session = BoardSession();
      session.updateState(_fixtureState());
      final backend = FakeVideoBackend();
      final video = VideoController(backend: backend);

      await tester.pumpWidget(MaterialApp(
        home: GroundTestScreen(session: session, videoController: video),
      ));
      await tester.pump();

      expect(find.text('Ground Test'), findsOneWidget);
      expect(find.byType(VideoPanel), findsOneWidget);
      expect(find.text('画面配置'), findsOneWidget);
      expect(find.text('Detector'), findsOneWidget); // tuning section
      expect(find.text('ISP'), findsOneWidget);
      video.dispose();
      session.disconnect();
    });

    testWidgets('rtsp off shows the unavailable panel instead of video',
        (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final session = BoardSession();
      session.updateState(_fixtureState(rtspOn: false));
      final backend = FakeVideoBackend();
      final video = VideoController(backend: backend);
      await tester.pumpWidget(MaterialApp(
        home: GroundTestScreen(session: session, videoController: video),
      ));
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
      await tester.pumpWidget(
          MaterialApp(home: ModeScreen(session: session)));
      await tester.pump();

      expect(find.text('Ground'), findsWidgets);
      // cancel the confirm dialog on switching (tap the segment, not the
      // description text which also contains "Flight")
      final flightSegment = find.descendant(
        of: find.byType(SegmentedButton<String>),
        matching: find.text('Flight'),
      );
      expect(flightSegment, findsOneWidget);
      await tester.tap(flightSegment);
      await tester.pumpAndSettle();
      expect(find.textContaining('确认切换？'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      session.disconnect();
    });
  });

  group('FilesScreen', () {
    testWidgets('renders remote entries from a fake backend',
        (tester) async {
      final ssh = _FakeSshFast();
      final dir = Directory.systemTemp.createTempSync('dart_ctrl_widget_');
      final controller = FileController(
        ssh: ssh,
        bookmarksFile: File('${dir.path}/bookmarks.json'),
      );
      await controller.init().then((_) => controller.cd('/release'));
      await tester.pumpWidget(MaterialApp(
        home: FilesScreen(host: 'board.test', controller: controller),
      ));
      await tester.pump();

      expect(find.textContaining('/release'), findsWidgets);
      expect(find.textContaining('flight_1.bin'), findsWidgets);
      expect(find.byIcon(Icons.download), findsWidgets);
      controller.dispose();
      dir.deleteSync(recursive: true);
    });
  });
}

class _FakeSshFast implements BoardSsh {
  @override
  String get host => 'board.test';

  @override
  Future<List<RemoteEntry>> ls(String path) async => [
        if (path == '/')
          const RemoteEntry(
              name: 'release',
              isDir: true,
              size: 4096,
              modified: '2026-09-07 20:00',
              linkTarget: null),
        if (path == '/release') ...[
          const RemoteEntry(
              name: 'flight_1.bin',
              isDir: false,
              size: 1048576,
              modified: '2026-09-07 22:11',
              linkTarget: null),
          const RemoteEntry(
              name: 'latest',
              isDir: false,
              size: 9,
              modified: '2026-09-07 22:12',
              linkTarget: 'flight_1.bin'),
        ],
      ];

  @override
  Future<bool> ping() async => true;

  @override
  Future<void> download(String remotePath, String localPath) async {}

  @override
  Future<void> upload(String localPath, String remotePath) async {}
}