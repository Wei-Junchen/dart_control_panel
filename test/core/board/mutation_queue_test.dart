import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:dart_control_panel/core/board/session/mutation_queue.dart';

void main() {
  group('MutationQueue', () {
    test('runs operations strictly serially', () async {
      final queue = MutationQueue();
      final order = <String>[];
      await Future.wait([
        queue.enqueue(() async {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          order.add('a');
        }),
        queue.enqueue(() async {
          await Future<void>.delayed(const Duration(milliseconds: 1));
          order.add('b');
        }),
        queue.enqueue(() async {
          order.add('c');
        }),
      ]);
      expect(order, ['a', 'b', 'c']);
      expect(queue.isBusy, isFalse);
    });

    test('busy flag tracks pending + running work', () async {
      final queue = MutationQueue();
      var closed = false;
      queue.addListener(() {
        if (!queue.isBusy) closed = true;
      });
      final future = queue.enqueue(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      expect(queue.isBusy, isTrue);
      queue.enqueue(() async {}); // queued, still busy
      expect(queue.pending, 2);
      await future;
      await Future<void>.delayed(Duration.zero);
      expect(queue.isBusy, isFalse);
      expect(closed, isTrue);
    });

    test('a failed operation does not break the chain', () async {
      final queue = MutationQueue();
      var secondRan = false;
      await expectLater(
        queue.enqueue(() async => throw StateError('boom')),
        throwsA(isA<StateError>()),
      );
      await queue.enqueue(() async => secondRan = true);
      expect(secondRan, isTrue);
      expect(queue.isBusy, isFalse);
    });

    test('enqueue returns the operation result', () async {
      final queue = MutationQueue();
      final result = await queue.enqueue(() async => 42);
      expect(result, 42);
    });

    test(
      'reset cancels queued work without overlapping the running one',
      () async {
        final queue = MutationQueue();
        final gate = Completer<void>();
        final started = Completer<void>();
        final order = <String>[];
        final first = queue.enqueue(() async {
          order.add('first start');
          started.complete();
          await gate.future;
          order.add('first end');
        });
        await started.future;
        final cancelled = queue.enqueue(() async => order.add('cancelled'));
        final cancellation = expectLater(cancelled, throwsStateError);
        queue.reset();
        final next = queue.enqueue(() async => order.add('next'));
        await Future<void>.delayed(Duration.zero);
        expect(order, ['first start']);
        expect(queue.pending, 3);
        gate.complete();
        await Future.wait([first, cancellation, next]);
        expect(order, ['first start', 'first end', 'next']);
        expect(queue.pending, 0);
        expect(queue.isBusy, isFalse);
      },
    );

    test('repeated resets do not corrupt the pending count', () async {
      final queue = MutationQueue();
      final cancelled = queue.enqueue(() async {});
      final cancellation = expectLater(cancelled, throwsStateError);
      queue.reset();
      queue.reset();
      await cancellation;
      await Future<void>.delayed(Duration.zero);
      expect(queue.pending, 0);
    });
  });
}
