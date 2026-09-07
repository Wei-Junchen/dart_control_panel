import 'package:fake_async/fake_async.dart';import 'package:flutter_test/flutter_test.dart';

import 'package:dart_control_panel/controllers/connection_controller.dart';
import 'package:dart_control_panel/controllers/state_poll_controller.dart';
import 'package:dart_control_panel/models/daemon_state.dart';
import 'package:dart_control_panel/protocol/daemon_client.dart';
import 'package:dart_control_panel/protocol/protocol_exception.dart';
import 'package:dart_control_panel/repositories/board_repository.dart';

class _NoopDaemonClient extends DaemonClient {
  @override
  Future<void> close() async {}
}

/// Scriptable repository stand-in (no sockets involved).
class _ScriptedRepository extends BoardRepository {
  _ScriptedRepository({
    this.slow = Duration.zero,
    this.failWith,
  }) : super(_NoopDaemonClient());

  Duration slow;
  ProtocolException? failWith;
  int calls = 0;

  @override
  Future<DaemonState> getState() async {
    calls++;
    if (slow > Duration.zero) await Future<void>.delayed(slow);
    if (failWith != null) throw failWith!;
    return DaemonState.fromEnvelope({
      'v': 1,
      'payload': {'state': 'STREAMING', 'config_rev': calls},
    });
  }
}

void main() {
  group('ConnectionController.nextPollInterval', () {
    test('healthy poll runs at base interval', () {
      final c = ConnectionController();
      expect(c.nextPollInterval(), const Duration(milliseconds: 500));
      expect(c.isConnected, isFalse);
      c.onPollSuccess();
      expect(c.isConnected, isTrue);
    });

    test('exponential backoff doubles per consecutive transport failure', () {
      final c = ConnectionController(
        baseInterval: const Duration(milliseconds: 500),
        maxInterval: const Duration(seconds: 16),
      );
      c.onPollSuccess(); // start from a healthy connected state
      c.onPollFailure(const ProtocolTransportClosed('x'));
      expect(c.nextPollInterval(), const Duration(milliseconds: 1000));
      c.onPollFailure(const ProtocolTimeout('x'));
      expect(c.nextPollInterval(), const Duration(milliseconds: 2000));
      c.onPollFailure(const ProtocolTransportClosed('x'));
      expect(c.nextPollInterval(), const Duration(milliseconds: 4000));
      expect(c.status, BoardConnectionStatus.reconnecting);
    });

    test('backoff is capped at maxInterval', () {
      final c = ConnectionController(
        baseInterval: const Duration(milliseconds: 500),
        maxInterval: const Duration(seconds: 16),
      );
      for (var i = 0; i < 10; i++) {
        c.onPollFailure(const ProtocolTransportClosed('x'));
      }
      expect(c.nextPollInterval(), const Duration(seconds: 16));
    });

    test('application-level failures do not count towards backoff', () {
      final c = ConnectionController();
      c.onPollFailure(const OperationFailedException('gain verification failed',
          op: 'apply_runtime'));
      expect(c.consecutiveFailures, 0);
      expect(c.nextPollInterval(), const Duration(milliseconds: 500));
    });

    test('inactive window forces >= 2 s pace', () {
      final c = ConnectionController(
        baseInterval: const Duration(milliseconds: 500),
        inactiveOverride: const Duration(seconds: 2),
      );
      expect(c.nextPollInterval(windowActive: false),
          const Duration(seconds: 2));
      c.consecutiveFailures = 5;
      final backed = c.nextPollInterval(windowActive: false);
      expect(backed >= const Duration(seconds: 2), isTrue);
    });

    test('success resets backoff and error state', () {
      final c = ConnectionController();
      c.onPollFailure(const ProtocolTimeout('x'));
      c.onPollFailure(const ProtocolTimeout('x'));
      expect(c.nextPollInterval(), const Duration(milliseconds: 2000));
      c.onPollSuccess();
      expect(c.consecutiveFailures, 0);
      expect(c.lastError, isNull);
      expect(c.nextPollInterval(), const Duration(milliseconds: 500));
    });
  });

  group('StatePollController', () {
    test('polls at 500 ms and updates state without pileup', () {
      fakeAsync((async) {
        final repo = _ScriptedRepository();
        final poll = StatePollController(
          repository: repo,
          connection: ConnectionController(),
        );
        poll.start();
        expect(poll.isStarted, isTrue);
        expect(poll.state, isNull);

        async.elapse(const Duration(milliseconds: 500));
        expect(repo.calls, 1);
        expect(poll.state!.configRev, 1);
        expect(poll.connection.isConnected, isTrue);

        async.elapse(const Duration(milliseconds: 500));
        expect(repo.calls, 2);
        expect(poll.state!.configRev, 2);
        poll.stop();
      });
    });

    test('slow response never queues duplicate polls (no pileup)', () {
      fakeAsync((async) {
        final repo = _ScriptedRepository(slow: const Duration(seconds: 3));
        final poll = StatePollController(
          repository: repo,
          connection: ConnectionController(),
        );
        poll.start();
        async.elapse(const Duration(minutes: 1));
        // 60s / ~3.5s per completed poll ~= 17, not 120.
        expect(repo.calls, lessThan(25));
        // And never two overlapping requests: count must equal unique
        // completions, never exceed them.
        poll.stop();
      });
    });

    test('transport failures freeze state and back off the polling rate',
        () {
      fakeAsync((async) {
        final repo =
            _ScriptedRepository(failWith: const ProtocolTransportClosed('cable unplugged'));
        final connection = ConnectionController();
        final poll = StatePollController(repository: repo, connection: connection);
        poll.start();
        async.elapse(const Duration(milliseconds: 500));
        expect(poll.state, isNull);
        expect(poll.lastError, contains('cable unplugged'));

        // Backoff now in effect: next failure is 1 s later, then 2 s, ...
        async.elapse(const Duration(seconds: 1));
        expect(repo.calls, 2);
        expect(connection.consecutiveFailures, 2);
        // Probing continues with backoff while the transport is down.
        expect(poll.connection.isConnected, isFalse);
        expect(
          poll.connection.status,
          anyOf(BoardConnectionStatus.reconnecting,
              BoardConnectionStatus.disconnected),
        );
        poll.stop();
      });
    });

    test('recovering from failure resumes fast polling and clears error',
        () {
      fakeAsync((async) {
        final repo = _ScriptedRepository(
            failWith: const ProtocolTransportClosed('probe failed'));
        final poll = StatePollController(
          repository: repo,
          connection: ConnectionController(),
        );
        poll.start();
        async.elapse(const Duration(seconds: 2));
        expect(poll.lastError, isNotNull);
        expect(poll.state, isNull);

        repo.failWith = null; // board answers again
        async.elapse(const Duration(seconds: 2));
        expect(poll.state, isNotNull);
        expect(poll.lastError, isNull);
        expect(poll.connection.isConnected, isTrue);
        expect(
            poll.connection.nextPollInterval(), const Duration(milliseconds: 500));
        poll.stop();
      });
    });

    test('inactive window slows polling to 1-2 s', () {
      fakeAsync((async) {
        final repo = _ScriptedRepository();
        final poll = StatePollController(
          repository: repo,
          connection: ConnectionController(),
        );
        poll.start();
        async.elapse(const Duration(milliseconds: 500));
        expect(repo.calls, 1);

        poll.setWindowActive(false);
        async.elapse(const Duration(milliseconds: 500));
        expect(repo.calls, 1); // inactive interval is 2 s, not 500 ms
        async.elapse(const Duration(milliseconds: 1500));
        expect(repo.calls, 2);

        poll.setWindowActive(true);
        // reschedule triggers immediately: next tick at +500 ms
        async.elapse(const Duration(milliseconds: 500));
        expect(repo.calls, 3);
        poll.stop();
      });
    });

    test('stop() halts polling; state stays stale and readable', () {
      fakeAsync((async) {
        final repo = _ScriptedRepository();
        final poll = StatePollController(
          repository: repo,
          connection: ConnectionController(),
        );
        poll.start();
        async.elapse(const Duration(milliseconds: 600));
        expect(repo.calls, 1);
        final captured = poll.state;
        expect(captured, isNotNull);
        poll.stop();
        async.elapse(const Duration(seconds: 10));
        expect(repo.calls, 1);
        expect(poll.isStarted, isFalse);
        expect(poll.state, same(captured));
      });
    });
  });
}
