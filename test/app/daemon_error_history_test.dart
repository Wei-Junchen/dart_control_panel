import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dart_control_panel/core/board/models/daemon_state.dart';
import 'package:dart_control_panel/shared/widgets/state_dashboard.dart';
import 'package:dart_control_panel/shared/widgets/metric_card.dart';

void main() {
  Future<List<StatRow>> rows(
    WidgetTester tester,
    Map<String, dynamic> payload,
  ) async {
    final state = DaemonState.fromEnvelope({'payload': payload});
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: DaemonCard(state: state)),
        ),
      ),
    );
    return tester.widgetList<StatRow>(find.byType(StatRow)).toList();
  }

  testWidgets(
    'healthy worker does not show recovered timeout as current error',
    (tester) async {
      final values = await rows(tester, {
        'state': 'STREAMING',
        'worker_pid': 935,
        'last_error': '',
        'worker_error': {
          'code': 'WORKER_READY_TIMEOUT',
          'active': false,
          'pid': 399,
        },
      });
      final current = values.singleWhere((r) => r.label == '当前异常');
      expect(current.value, '无');
      expect(current.highlight, isFalse);
      final history = values.singleWhere((r) => r.label == '历史异常（已恢复）');
      expect(history.value, '视觉程序就绪超时');
      expect(history.highlight, isFalse);
    },
  );
  testWidgets('active error still shows full identity and is highlighted', (
    tester,
  ) async {
    final values = await rows(tester, {
      'state': 'ERROR',
      'worker_error': {'code': 'WORKER_READY_TIMEOUT', 'active': true},
    });
    final current = values.singleWhere((r) => r.label == '当前异常');
    expect(current.value, contains('WORKER_READY_TIMEOUT'));
    expect(current.highlight, isTrue);
    expect(values.where((r) => r.label == '历史异常（已恢复）'), isEmpty);
  });
  testWidgets(
    'new daemon error is not hidden by an older recovered worker error',
    (tester) async {
      final values = await rows(tester, {
        'last_error': 'storage unavailable',
        'worker_error': {'code': 'WORKER_READY_TIMEOUT', 'active': false},
      });
      final current = values.singleWhere((r) => r.label == '当前异常');
      expect(current.value, 'storage unavailable');
      expect(current.highlight, isTrue);
    },
  );
}
