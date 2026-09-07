import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dart_control_panel/controllers/telemetry_controller.dart';
import 'package:dart_control_panel/models/daemon_state.dart';
import 'package:dart_control_panel/protocol/daemon_client.dart';
import 'package:dart_control_panel/repositories/board_repository.dart';

import 'helpers/fixture_daemon.dart';

void main() {
  late Map<String, String> fixtures;

  setUpAll(() async {
    fixtures = {
      for (final name in ['get_state_ok'])
        name: File('test/fixtures/exchanges/$name.ndjson').readAsStringSync(),
    };
  });

  group('set_mode repository op', () {
    test('sends the mode argument and unwraps state', () async {
      final daemon = await FixtureDaemon.start(
          (op) async => fixtures['get_state_ok']!);
      final repo = BoardRepository(
          DaemonClient(host: '127.0.0.1', port: daemon.port));
      final state = await repo.setMode('flight');
      await repo.close();
      await daemon.stop();
      expect(daemon.requests.single.$1, 'set_mode');
      expect(daemon.requests.single.$2, {'mode': 'flight'});
      expect(state.state, 'STREAMING');
    });
  });

  group('telemetry flight envelope', () {
    test('flight profile emits NaN fps and wider angles', () async {
      final controller = TelemetryController();
      controller.start();
      controller.setModeProfile('flight');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await controller.stop();

      final samples = controller.samples;
      expect(samples, isNotEmpty);
      final last = samples.last;
      expect(last.valueOf('fps').isNaN, isTrue);
      expect(last.valueOf('air_speed'), greaterThan(30));
      for (final p in samples) {
        expect(p.valueOf('pitch').abs(), lessThan(45));
        expect(p.valueOf('roll').abs(), lessThan(180));
      }
      controller.dispose();

      // ground profile keeps fps meaningful
      final ground = TelemetryController();
      ground.start();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await ground.stop();
      expect(ground.samples, isNotEmpty);
      expect(ground.samples.last.valueOf('fps').isNaN, isFalse);
      ground.dispose();
    });
  });

  group('DaemonState.mode forward compatibility', () {
    test('missing mode defaults to ground', () {
      final state = DaemonState.fromEnvelope({
        'v': 1,
        'payload': {'state': 'STREAMING'},
      });
      expect(state.mode, 'ground');
      expect(state.modePending, isNull);
      expect(state.modeTransition, isFalse);
    });

    test('flight mode with pending transition parses', () {
      final state = DaemonState.fromEnvelope({
        'v': 1,
        'payload': {
          'state': 'STARTING',
          'mode': 'flight',
          'mode_pending': 'ground',
          'mode_transition': true,
        },
      });
      expect(state.mode, 'flight');
      expect(state.modePending, 'ground');
      expect(state.modeTransition, isTrue);
      expect(state.isTransitional, isTrue);
    });
  });

  group('TelemetryController mode profile wiring', () {
    test('unknown channel names are tolerated', () async {
      final controller = TelemetryController();
      controller.start();
      controller.setModeProfile('unknown'); // treated as ground
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await controller.stop();
      expect(controller.samples.last.valueOf('fps').isNaN, isFalse);
      controller.dispose();
    });
  });
}

// ignore: unused_element
