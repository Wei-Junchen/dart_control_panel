import 'dart:async';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dart_control_panel/core/board/session/auto_board_connector.dart';
import 'package:dart_control_panel/core/board/session/board_discovery.dart';

const board = BoardCandidate('10.2.3.1', '10.2.3.55', 'wlan0');

void main() {
  test('startup discovery retries after Wi-Fi arrives then connects once', () {
    fakeAsync((clock) {
      var attempts = 0, connections = 0;
      final connector = AutoBoardConnector(
        discover: () async => ++attempts > 1 ? board : null,
        onFound: (found) async {
          expect(found.host, '10.2.3.1');
          ++connections;
          return true;
        },
      );
      connector.start();
      connector.start();
      clock.flushMicrotasks();
      expect(attempts, 1);
      expect(connector.running, isTrue);
      clock.elapse(const Duration(seconds: 3));
      clock.flushMicrotasks();
      expect(connections, 1);
      expect(connector.running, isFalse);
      clock.elapse(const Duration(seconds: 30));
      expect(attempts, 2);
      connector.dispose();
    });
  });

  test('manual mode/disconnect invalidates an outstanding probe', () async {
    final pending = Completer<BoardCandidate?>();
    var connections = 0;
    final connector = AutoBoardConnector(
      discover: () => pending.future,
      onFound: (_) async {
        ++connections;
        return true;
      },
    );
    connector.start();
    connector.stop();
    pending.complete(board);
    await Future<void>.delayed(Duration.zero);
    expect(connections, 0);
    expect(connector.running, isFalse);
    connector.dispose();
  });

  test(
    'dispose prevents late completion from connecting or scheduling',
    () async {
      final pending = Completer<BoardCandidate?>();
      var connections = 0;
      final connector = AutoBoardConnector(
        discover: () => pending.future,
        onFound: (_) async {
          ++connections;
          return true;
        },
      );
      connector.start();
      connector.dispose();
      pending.complete(board);
      await Future<void>.delayed(Duration.zero);
      expect(connections, 0);
    },
  );

  test(
    'network exceptions and failed connection are retried without overlapping',
    () {
      fakeAsync((clock) {
        var attempts = 0, connections = 0;
        final connector = AutoBoardConnector(
          discover: () async {
            if (++attempts == 1) throw StateError('no network');
            return board;
          },
          onFound: (_) async => ++connections > 1,
        );
        connector.start();
        clock.flushMicrotasks();
        expect(connector.message, contains('网络暂不可用'));
        clock.elapse(const Duration(seconds: 3));
        clock.flushMicrotasks();
        expect(connections, 1);
        expect(connector.running, isTrue);
        clock.elapse(const Duration(seconds: 3));
        clock.flushMicrotasks();
        expect(connections, 2);
        expect(connector.running, isFalse);
        connector.dispose();
      });
    },
  );
}
