import 'package:flutter_test/flutter_test.dart';
import 'package:dart_control_panel/core/board/models/daemon_state.dart';

void main() {
  DaemonState parse(dynamic error) => DaemonState.fromEnvelope({
    'payload': {'worker_error': error},
  });
  test('old board without structured error remains compatible', () {
    expect(parse(null).workerError, isNull);
    expect(parse('invalid').workerError, isNull);
  });
  test('camera recovery exposes category, stage and native status', () {
    final error = parse({
      'code': 'CAMERA_RECOVERY_EXHAUSTED',
      'stage': 'camera.recovery',
      'message': 'frame acquisition failed',
      'active': true,
      'exit_code': 69,
      'native_code': -123,
    }).workerError!;
    expect(error.title, contains('重建恢复失败'));
    expect(error.suggestion, contains('不一定是物理断连'));
    expect(error.details, contains('exit=69'));
    expect(error.details, contains('0xffffff85'));
    expect(error.active, isTrue);
  });
  test('unknown code and signal are not confused with a numeric exit', () {
    final error = parse({
      'code': 'FUTURE_ERROR',
      'message': 'future detail',
      'exit_code': null,
      'signal': 9,
      'active': false,
    }).workerError!;
    expect(error.title, '视觉程序异常退出');
    expect(error.details, contains('FUTURE_ERROR'));
    expect(error.details, contains('signal=9'));
    expect(error.details, isNot(contains('exit=')));
    expect(error.active, isFalse);
  });
}
