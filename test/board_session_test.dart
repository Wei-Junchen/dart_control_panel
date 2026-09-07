import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dart_control_panel/controllers/board_session.dart';
import 'package:dart_control_panel/protocol/protocol_exception.dart';

import 'helpers/fixture_daemon.dart';

Future<String> _fixture(String name) async {
  return File('test/fixtures/exchanges/$name.ndjson').readAsStringSync();
}

Future<void> _waitLoop() async {
  // let the session's internal refresh (extra get_state) settle
  await Future<void>.delayed(const Duration(milliseconds: 30));
}

void main() {
  late Map<String, String> fixtures;

  setUpAll(() async {
    fixtures = {
      for (final name in [
        'get_state_ok',
        'lifecycle_rejected',
        'apply_runtime_ok',
      ])
        name: await _fixture(name),
    };
  });

  group('BoardSession', () {
    test('connect probes once and stores state', () async {
      final daemon = await FixtureDaemon.start(
          (op) async => fixtures['get_state_ok']!);
      final session = BoardSession(host: '127.0.0.1', port: daemon.port);
      await session.connect();
      expect(session.connected, isTrue);
      expect(session.state, isNotNull, reason: 'state loaded during connect');
      await session.disconnect();
      await daemon.stop();
    });

    test('successful mutation sets status and refreshes state', () async {
      final daemon = await FixtureDaemon.start(
          (op) async => fixtures['get_state_ok']!);
      final session = BoardSession(host: '127.0.0.1', port: daemon.port);
      await session.connect();
      final before = daemon.requests.length;

      final state = await session.mutate('stop_worker', (repo) async {
        final s = await repo.stopWorker();
        expect(s.state, 'STREAMING');
        return s;
      });
      await _waitLoop();

      expect(state.state, 'STREAMING');
      expect(session.statusMessage, contains('stop_worker'));
      expect(session.statusError, isFalse);
      // connect probe + mutation + refresh
      expect(daemon.requests.length, greaterThan(before + 1));

      await session.disconnect();
      await daemon.stop();
    });

    test('rejected mutation surfaces daemon error and refreshes real state',
        () async {
      final daemon = await FixtureDaemon.start((op) async {
        if (op == 'apply_readout_profile') return fixtures['lifecycle_rejected']!;
        return fixtures['get_state_ok']!;
      });
      final session = BoardSession(host: '127.0.0.1', port: daemon.port);
      await session.connect();

      expect(
        () => session.mutate('apply_readout_profile',
            (repo) => repo.applyReadoutProfile('full_square_360')),
        throwsA(isA<OperationFailedException>()),
      );
      await _waitLoop();

      // rollback result shown to the user, and a get_state refresh followed
      expect(session.statusMessage, contains('rolled back'));
      expect(session.statusError, isTrue);
      expect(session.state, isNotNull);

      await session.disconnect();
      await daemon.stop();
    });

    test('mutations queue: two rapid ops run in order', () async {
      final daemon = await FixtureDaemon.start(
          (op) async => fixtures['get_state_ok']!);
      final session = BoardSession(host: '127.0.0.1', port: daemon.port);
      await session.connect();
      final seen = <String>[];
      final futures = <Future<void>>[
        session.mutate('a', (repo) async {
          seen.add('a');
        }),
        session.mutate('b', (repo) async {
          seen.add('b');
        }),
      ];
      expect(session.busy, isTrue);
      await Future.wait(futures);
      expect(seen, ['a', 'b']);
      expect(session.busy, isFalse);
      await session.disconnect();
      await daemon.stop();
    });

    test('disconnect clears state and queue', () async {
      final daemon = await FixtureDaemon.start(
          (op) async => fixtures['get_state_ok']!);
      final session = BoardSession(host: '127.0.0.1', port: daemon.port);
      await session.connect();
      await session.disconnect();
      expect(session.connected, isFalse);
      expect(session.state, isNull);
      expect(session.busy, isFalse);
      await daemon.stop();
    });
  });
}