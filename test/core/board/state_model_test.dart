import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dart_control_panel/core/board/models/daemon_state.dart';
import 'package:dart_control_panel/core/board/models/profile.dart';

void main() {
  late Map<String, dynamic> fixtureEnvelope;

  setUpAll(() {
    final raw = File(
      'test/fixtures/payloads/state_envelope_full.json',
    ).readAsStringSync();
    fixtureEnvelope = jsonDecode(raw) as Map<String, dynamic>;
  });

  group('DaemonState.fromEnvelope', () {
    test('unwraps the state envelope and parses all sections', () {
      final state = DaemonState.fromEnvelope(fixtureEnvelope);
      expect(state.v, 1);
      expect(state.type, 'state');
      expect(state.seq, 101);
      expect(state.monoUs, 123456789);

      expect(state.state, 'STREAMING');
      expect(state.profile, 'full_wide_640x360');
      expect(state.rotation, 0);
      expect(state.configRev, 184);
      expect(state.lastKnownGood, 'full_wide_640x360');
      expect(state.lastError, '');
      expect(state.workerPid, 363);
      expect(state.daemonUptimeS, closeTo(3600.5, 0.001));
      expect(state.restarts, 1);

      expect(state.features.uartEnabled, isTrue);
      expect(state.features.overlay, isTrue);

      expect(state.resources.vbActive, isTrue);
      expect(state.resources.vbPoolCount, 7);
      expect(state.resources.mipiLoaded, isTrue);
      expect(state.resources.temperatureC, closeTo(51.2, 0.001));
      expect(state.resources.powerW, isNull);
      expect(state.resources.needsReboot, isFalse);
      expect(state.fileService.enabled, isTrue);
      expect(state.fileService.available, isTrue);
      expect(state.fileService.readOnly, isTrue);
      expect(state.fileService.range, isTrue);
      expect(state.fileService.port, 9002);
    });

    test('parses worker performance, lifecycle and target', () {
      final w = DaemonState.fromEnvelope(fixtureEnvelope).worker!;
      expect(w.frameCount, 9000);
      expect(w.timestampMs, 123456);

      expect(w.lifecycle.state, 'STREAMING');
      expect(w.lifecycle.reg0100, 9);
      expect(w.lifecycle.standbyCount, 1);
      expect(w.lifecycle.wakeCount, 1);
      expect(w.lifecycle.wakeFailures, 0);

      expect(w.performance.fps, closeTo(79.8, 0.001));
      expect(w.performance.requestedFps, 80);
      expect(w.performance.detectionFps, closeTo(79.8, 0.001));
      expect(w.performance.processMaxMs, closeTo(0.8, 0.001));

      expect(w.target.found, isTrue);
      expect(w.target.x, 180);
      expect(w.target.y, 120);
      expect(w.target.pixels, 87);
      expect(w.target.area, 240);
      expect(w.target.rect, [170, 110, 20, 24]);
      expect(w.target.brightness, closeTo(73.0, 0.001));
    });

    test('parses vision with green_score details', () {
      final v = DaemonState.fromEnvelope(fixtureEnvelope).worker!.vision;
      expect(v.greenScore.yMin, 20);
      expect(v.greenScore.scoreMin, 60);
      expect(v.detectRoi, [40, 40, 280, 160]);
      expect(v.searchRadius, 20);
      expect(v.detectEveryN, 1);
      expect(v.detectionFrames, 8990);
      expect(v.profileUs.finePasses, 200);
      expect(v.profileUs.coarseSamples, 11200);
      expect(v.profileUs.coarsePasses, 1);
    });

    test('requested vs actual camera values are separate', () {
      final c = DaemonState.fromEnvelope(fixtureEnvelope).worker!.camera;
      expect(c.exposureUs, 1000); // requested
      expect(c.again, 1024);
      expect(c.dgain, 1024);
      expect(c.awbAuto, isFalse);
      expect(c.output, [640, 360]);
      expect(c.sensor, [1280, 720]);

      final isp = c.isp;
      expect(isp.valid, isTrue);
      expect(isp.exposureUs, 999); // actual readback
      expect(isp.again, 1024);
      expect(isp.iso, 100);
      expect(isp.averageLuma, 7);
      expect(isp.wbGain, [2095, 1024, 1024, 1974]);
      expect(isp.colorTemperature, 5432);
    });

    test('parses view, overlay, control, uart, stream, debug', () {
      final w = DaemonState.fromEnvelope(fixtureEnvelope).worker!;
      expect(w.view.profile, 'wide_640x360');
      expect(w.view.cropEnabled, isFalse);
      expect(w.view.output, [640, 360]);
      expect(w.view.visibleOffsetX, 0);

      expect(w.overlay.enabled, isTrue);
      expect(w.overlay.roi, isTrue);
      expect(w.overlay.frameSync, isTrue);
      expect(w.overlay.syncTimeoutMs, 6);
      expect(w.overlay.matchedFrames, 8988);
      expect(w.overlay.missedFrames, 2);
      expect(w.overlay.lastWaitUs, 410);
      expect(w.overlay.maxWaitUs, 6120);
      expect(w.overlay.detectionFrameId, 9000);

      expect(w.control.mode, 'angle_rad');
      expect(w.control.fx, closeTo(277.0, 0.001));
      expect(w.control.rollUnit, 'deg');

      expect(w.uart.open, isTrue);
      expect(w.uart.txPackets, 8990);
      expect(w.uart.txMinGapUs, 12400);
      expect(w.uart.telemetryValid, isFalse);
      expect(w.uart.decodeErrors, 2);
      expect(w.uart.rxLayout['packet_size'], 123);
      expect(w.uart.values['pitch'], 1.25);
      expect(w.uart.values['battery_mv'], 12000);

      expect(w.stream.rtspEnabled, isTrue);
      expect(w.stream.rtspPort, 8554);
      expect(w.stream.sourceFrames, 9000);
      expect(w.stream.encodedBytes, 10485760);

      expect(w.debug.clients, 1);
      expect(w.debug.commands, 3);
    });
  });

  group('forward compatibility', () {
    test('unknown top-level and nested fields are ignored', () {
      final extra =
          jsonDecode(
                File(
                  'test/fixtures/exchanges/get_state_extra_fields.ndjson',
                ).readAsStringSync().split('\n')[1],
              )
              as Map<String, dynamic>;
      final envelope = extra['payload'] as Map<String, dynamic>;
      final state = DaemonState.fromEnvelope(envelope);
      expect(state.state, 'STREAMING');
      expect(state.configRev, 185);
      expect(state.worker!.camera.isp.colorTemperature, 5432);
      expect((state.envelope['payload'] as Map)['new_top_level_thing'], {
        'a': [1, 2, 3],
      });
    });

    test('missing sections yield defaults, never crash', () {
      final state = DaemonState.fromEnvelope({
        'v': 1,
        'type': 'state',
        'payload': {'state': 'STOPPED'},
      });
      expect(state.state, 'STOPPED');
      expect(state.profile, '');
      expect(state.features.rtsp, isFalse);
      expect(state.resources.temperatureC, isNull);
      expect(state.worker, isNull);
      expect(state.workerStatus, '');
    });

    test('daemon state envelope may be missing entirely', () {
      final state = DaemonState.fromEnvelope({});
      expect(state.state, '');
      expect(state.configRev, 0);
      expect(state.worker, isNull);
    });

    test('worker missing entirely is tolerated', () {
      final state = DaemonState.fromEnvelope({
        'v': 1,
        'payload': {'state': 'STOPPED'},
      });
      expect(state.state, 'STOPPED');
      expect(state.worker, isNull);
    });

    test('whole worker present but empty', () {
      final state = DaemonState.fromEnvelope({
        'v': 1,
        'payload': {'state': 'STOPPED', 'worker': <String, dynamic>{}},
      });
      final w = state.worker!;
      expect(w.performance.fps, 0);
      expect(w.target.found, isFalse);
      expect(w.uart.open, isFalse);
    });
  });

  group('Profile.fromJson', () {
    test('parses full profile', () {
      final p = Profile.fromJson({
        'readout': 'full_1280x720_80',
        'view': 'wide_640x360',
        'status': 'stable',
        'expected': {
          'sensor': [1280, 720],
          'output': [640, 360],
          'fps': 80,
        },
      });
      expect(p.readout, 'full_1280x720_80');
      expect(p.view, 'wide_640x360');
      expect(p.status, 'stable');
      expect(p.expected!.sensor, [1280, 720]);
      expect(p.expected!.output, [640, 360]);
      expect(p.expected!.fps, closeTo(80, 0.001));
    });

    test('status is optional; unknown fields ignored', () {
      final p = Profile.fromJson({
        'readout': 'future_readout',
        'view': 'future_view',
        'unknown_kind': 'thing',
      });
      expect(p.readout, 'future_readout');
      expect(p.view, 'future_view');
      expect(p.status, '');
      expect(p.expected, isNull);
    });
  });

  group('state enum helpers', () {
    test('transitional states are flagged', () {
      for (final s in ['STARTING', 'STANDBY_PENDING', 'WAKING', 'STOPPING']) {
        expect(DaemonState.isTransitionalState(s), isTrue, reason: s);
      }
      for (final s in ['STREAMING', 'STOPPED', 'STANDBY', 'ERROR']) {
        expect(DaemonState.isTransitionalState(s), isFalse, reason: s);
      }
      expect(DaemonState.isTransitionalState('FUTURE_STATE'), isFalse);
    });
  });
}
