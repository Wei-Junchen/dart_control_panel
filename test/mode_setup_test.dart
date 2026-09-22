import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dart_control_panel/models/daemon_state.dart';
import 'package:dart_control_panel/protocol/daemon_client.dart';
import 'package:dart_control_panel/repositories/board_repository.dart';
import 'package:dart_control_panel/telemetry/udp_telemetry_source.dart';
import 'helpers/fixture_daemon.dart';

void main() {
  test('set_operating_mode sends mode and unwraps state', () async {
    final fixture = File(
      'test/fixtures/exchanges/get_state_ok.ndjson',
    ).readAsStringSync();
    final daemon = await FixtureDaemon.start((op) async => fixture);
    final repo = BoardRepository(
      DaemonClient(host: '127.0.0.1', port: daemon.port),
    );
    final state = await repo.setOperatingMode('flight');
    await repo.close();
    await daemon.stop();
    expect(daemon.requests.single.$1, 'set_operating_mode');
    expect(daemon.requests.single.$2, {'mode': 'flight'});
    expect(state.state, 'STREAMING');
  });

  test('current nested mode schema parses and locks flight settings', () {
    final state = DaemonState.fromEnvelope({
      'v': 1,
      'payload': {
        'state': 'STREAMING',
        'operating_mode': 'flight',
        'mode': {'name': 'flight', 'image_settings_locked': true},
        'flight': {
          'active': true,
          'state': 'ACTIVE',
          'trigger_source': 'tcp',
          'record_path': '/recordings/a.h264',
        },
      },
    });
    expect(state.mode, 'flight');
    expect(state.imageSettingsLocked, isTrue);
    expect(state.flight.active, isTrue);
    expect(state.flight.state, 'ACTIVE');
    expect(state.flight.triggerSource, 'tcp');
  });

  test('FireWater packet parser retains board keys', () {
    final values = UdpTelemetrySource.parseFireWater(
      'seq:42,frame:99,found:1,target_x:123.5,capture_fps:80.1\n',
    );
    expect(values['seq'], 42);
    expect(values['target_x'], 123.5);
    expect(values['capture_fps'], 80.1);
  });
}
