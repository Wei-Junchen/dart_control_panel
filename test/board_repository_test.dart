import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dart_control_panel/protocol/daemon_client.dart';
import 'package:dart_control_panel/protocol/protocol_exception.dart';
import 'package:dart_control_panel/repositories/board_repository.dart';
import 'helpers/fixture_daemon.dart';

/// Loads a two-line NDJSON exchange fixture and serves it verbatim.
Future<String> _fixture(String name) async {
  return File('test/fixtures/exchanges/$name.ndjson').readAsStringSync();
}

void main() {
  late Map<String, String> fixtures;

  setUpAll(() async {
    fixtures = {
      for (final name in [
        'get_state_ok',
        'get_state_fail',
        'invalid_request',
        'get_profiles_ok',
        'get_schema_ok',
        'heartbeat_ok',
        'get_state_extra_fields',
        'apply_runtime_ok',
        'apply_runtime_fail',
        'reboot_board_ok',
        'lifecycle_rejected',
      ])
        name: await _fixture(name),
    };
  });

  group('BoardRepository', () {
    test('getState unwraps result.payload.payload into DaemonState', () async {
      final daemon = await FixtureDaemon.start((op) async => fixtures['get_state_ok']!);
      final repo = BoardRepository(
        DaemonClient(host: '127.0.0.1', port: daemon.port),
      );
      final state = await repo.getState();
      await repo.close();
      await daemon.stop();

      expect(state.state, 'STREAMING');
      expect(state.configRev, 184);
      expect(state.profile, 'full_wide_640x360');
      expect(state.worker!.performance.fps, closeTo(79.8, 0.001));
      expect(state.worker!.target.x, 180);
      expect(state.worker!.camera.isp.colorTemperature, 5432);
    });

    test('getProfiles returns map of typed profiles', () async {
      final daemon = await FixtureDaemon.start((op) async => fixtures['get_profiles_ok']!);
      final repo = BoardRepository(
        DaemonClient(host: '127.0.0.1', port: daemon.port),
      );
      final profiles = await repo.getProfiles();
      await repo.close();
      await daemon.stop();

      expect(profiles.keys, containsAll(['full_wide_640x360', 'full_square_360']));
      expect(profiles['full_wide_640x360']!.expected!.fps, closeTo(80, 0.001));
      // unknown future profile still parses without crashing
      expect(profiles['new_future_profile']!.expected, isNull);
      expect(profiles['new_future_profile']!.view, 'future_view');
    });

    test('getSchema returns raw payload', () async {
      final daemon = await FixtureDaemon.start((op) async => fixtures['get_schema_ok']!);
      final repo = BoardRepository(
        DaemonClient(host: '127.0.0.1', port: daemon.port),
      );
      final schema = await repo.getSchema();
      await repo.close();
      await daemon.stop();

      expect(schema['ops'], contains('start_worker'));
      expect((schema['presets'] as Map)['competition'], isNotNull);
      expect(schema['runtime_keys'], isA<List<dynamic>>());
    });

    test('operation failure surfaces as OperationFailedException', () async {
      final daemon = await FixtureDaemon.start((op) async => fixtures['get_state_fail']!);
      final repo = BoardRepository(
        DaemonClient(host: '127.0.0.1', port: daemon.port),
      );
      await expectLater(
        repo.getState(),
        throwsA(isA<OperationFailedException>()),
      );
      await repo.close();
      await daemon.stop();
    });

    test('unknown fields in state are preserved in the raw envelope', () async {
      final daemon = await FixtureDaemon.start(
          (op) async => fixtures['get_state_extra_fields']!);
      final repo = BoardRepository(
        DaemonClient(host: '127.0.0.1', port: daemon.port),
      );
      final state = await repo.getState();
      await repo.close();
      await daemon.stop();

      expect(state.configRev, 185);
      expect(
        (state.envelope['payload'] as Map)['new_top_level_thing'],
        {'a': [1, 2, 3]},
      );
    });

    test('getState continues to work when fixture exchange is unchunked', () async {
      final daemon = await FixtureDaemon.start((op) async => fixtures['heartbeat_ok']!);
      final repo = BoardRepository(
        DaemonClient(host: '127.0.0.1', port: daemon.port),
      );
      final hb = await repo.heartbeat();
      await repo.close();
      await daemon.stop();
      expect(hb['daemon_state'], 'STREAMING');
    });

    test('applyRuntime sends only the given args, then refreshes state',
        () async {
      final daemon = await FixtureDaemon.start((op) async {
        if (op == 'apply_runtime') return fixtures['apply_runtime_ok']!;
        return fixtures['get_state_ok']!;
      });
      final repo = BoardRepository(
        DaemonClient(host: '127.0.0.1', port: daemon.port),
      );
      final result = await repo.applyRuntime({
        'again': 2048,
        'exposure_us': 1500,
      });
      await repo.close();
      await daemon.stop();

      expect(result.message, 'applied again awb_auto exposure_us');
      expect(result.state.configRev, 184);
      expect(daemon.requests.map((r) => r.$1),
          containsAllInOrder(['apply_runtime', 'get_state']));
      final applied = daemon.requests.first.$2;
      expect(applied, {'again': 2048, 'exposure_us': 1500});
    });

    test('applyRuntime surfaces daemon rejection, no state refresh', () async {
      final daemon = await FixtureDaemon.start((op) async {
        if (op == 'apply_runtime') return fixtures['apply_runtime_fail']!;
        return fixtures['get_state_ok']!;
      });
      final repo = BoardRepository(
        DaemonClient(host: '127.0.0.1', port: daemon.port),
      );
      await expectLater(
        repo.applyRuntime({'again': 1024}),
        throwsA(isA<OperationFailedException>()),
      );
      await repo.close();
      await daemon.stop();
      expect(daemon.requests.map((r) => r.$1), ['apply_runtime']);
    });

    group('P4 lifecycle ops', () {
      late FixtureDaemon daemon;
      late BoardRepository repo;

      Future<FixtureDaemon> serveStateOps() => FixtureDaemon.start(
          (op) async => fixtures['get_state_ok']!);

      tearDown(() async {
        await repo.close();
        await daemon.stop();
      });

      test('startWorker sends the profile arg and unwraps state', () async {
        daemon = await serveStateOps();
        repo = BoardRepository(DaemonClient(host: '127.0.0.1', port: daemon.port));
        final state = await repo.startWorker(profile: 'full_square_360');
        expect(state.state, 'STREAMING');
        expect(daemon.requests.single.$1, 'start_worker');
        expect(daemon.requests.single.$2, {'profile': 'full_square_360'});
      });

      test('startWorker without profile sends empty args {}', () async {
        daemon = await serveStateOps();
        repo = BoardRepository(DaemonClient(host: '127.0.0.1', port: daemon.port));
        await repo.startWorker();
        expect(daemon.requests.single.$2, isEmpty);
      });

      test('lifecycle ops produce correct op names', () async {
        daemon = await serveStateOps();
        repo = BoardRepository(DaemonClient(host: '127.0.0.1', port: daemon.port));
        await repo.stopWorker();
        await repo.restartWorker();
        await repo.cameraStandby();
        await repo.cameraWake();
        await repo.applyReadoutProfile('full_square_360');
        await repo.applyFeaturePreset('debug');
        await repo.startRecording(recordEveryN: 2);
        await repo.stopRecording();
        await repo.rotateRecording();
        await repo.setUart(true);
        await repo.setRotation(90);
        expect(daemon.ops, [
          'stop_worker',
          'restart_worker',
          'camera_standby',
          'camera_wake',
          'apply_readout_profile',
          'apply_feature_preset',
          'start_recording',
          'stop_recording',
          'rotate_recording',
          'set_uart',
          'set_rotation',
        ]);
        expect(daemon.requests.last.$2, {'degrees': 90});
      });

      test('setFeatures sends only rtsp/uart explicitly provided', () async {
        daemon = await serveStateOps();
        repo = BoardRepository(DaemonClient(host: '127.0.0.1', port: daemon.port));
        await repo.setFeatures(rtsp: true, uart: false);
        expect(daemon.requests.single.$2, {'rtsp': true, 'uart': false});
      });

      test('setFeatures sends only record_every_n when that is provided',
          () async {
        daemon = await serveStateOps();
        repo = BoardRepository(DaemonClient(host: '127.0.0.1', port: daemon.port));
        await repo.setFeatures(recordEveryN: 4);
        expect(daemon.requests.single.$2, {'record_every_n': 4});
      });

      test('rejected lifecycle op throws OperationFailed with daemon error',
          () async {
        daemon = await FixtureDaemon.start((op) async {
          if (op == 'apply_readout_profile') return fixtures['lifecycle_rejected']!;
          return fixtures['get_state_ok']!;
        });
        repo = BoardRepository(DaemonClient(host: '127.0.0.1', port: daemon.port));
        await expectLater(
          repo.applyReadoutProfile('full_square_360'),
          throwsA(isA<OperationFailedException>()
              .having((e) => e.message, 'message', contains('rolled back'))),
        );
      });

      test('rebootBoard requires confirm and returns the schedule payload',
          () async {
        daemon = await FixtureDaemon.start(
            (op) async => fixtures['reboot_board_ok']!);
        repo = BoardRepository(DaemonClient(host: '127.0.0.1', port: daemon.port));
        final schedule = await repo.rebootBoard(confirm: true);
        expect(daemon.requests.single.$2, {'confirm': true});
        expect(schedule['delay_s'], 5);
        expect(schedule['reboot_at_mono_us'], 123456789012);
      });
    });
  });
}
