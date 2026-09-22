import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dart_control_panel/controllers/mutation_queue.dart';

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

    test('reset drops queued work and clears busy', () {
      fakeAsync((async) {
        final queue = MutationQueue();
        final gate = <Completer<void>>[];
        queue.enqueue(() {
          final c = Completer<void>();
          gate.add(c);
          return c.future;
        });
        queue.enqueue(() async {});
        expect(queue.pending, 2);
        queue.reset();
        expect(queue.isBusy, isFalse);
        expect(queue.pending, 0);
      });
    });
  });
}
