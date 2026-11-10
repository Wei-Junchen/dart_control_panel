import 'package:dart_control_panel/core/board/models/json_view.dart';

/// Stable worker failure identity; numeric exits are transport details, not UI.
class WorkerError {
  WorkerError(JsonView v)
    : code = v.str('code', 'WORKER_UNKNOWN_EXIT'),
      stage = v.str('stage'),
      message = v.str('message'),
      hint = v.str('hint'),
      active = v.flag('active', true),
      severity = v.str('severity', 'error'),
      exitCode = v.num_('exit_code')?.toInt(),
      signal = v.num_('signal')?.toInt(),
      nativeCode = v.num_('native_code')?.toInt();

  final String code, stage, message, hint, severity;
  final bool active;
  final int? exitCode, signal, nativeCode;

  String get title => switch (code) {
    'CONFIGURATION_INVALID' => '板端配置不合法',
    'CAMERA_INITIALIZATION_FAILED' => '相机初始化失败',
    'MEDIA_INITIALIZATION_FAILED' => '编码或录像初始化失败',
    'SERVICES_INITIALIZATION_FAILED' => '板端通信服务启动失败',
    'CAMERA_CAPTURE_FAILED' => '相机持续取帧失败',
    'CAMERA_RECOVERY_EXHAUSTED' => '相机取帧异常，重建恢复失败',
    'WORKER_INTERNAL_EXCEPTION' => '视觉程序发生未处理异常',
    'FLIGHT_CONTROL_FAILED' => '飞行激活或录像控制失败',
    'WORKER_PARENT_LOST' => '视觉程序失去管理进程',
    'UART_OPEN_FAILED' => '必需的串口无法打开',
    'UART_RECOVERY_REQUESTED' => '串口请求恢复',
    'MCU_HELLO_RESTART' => 'MCU 重启，重新握手',
    'WORKER_SIGNALLED' => '视觉程序被信号终止',
    'WORKER_READY_TIMEOUT' => '视觉程序就绪超时',
    'WORKER_UNEXPECTED_EXIT' => '视觉程序未经请求自行退出',
    'WORKER_WAIT_FAILED' => '无法取得视觉程序退出状态',
    _ => '视觉程序异常退出',
  };

  String get suggestion => switch (code) {
    'CAMERA_INITIALIZATION_FAILED' ||
    'CAMERA_CAPTURE_FAILED' ||
    'CAMERA_RECOVERY_EXHAUSTED' => '检查相机供电、排线及 VI/VPSS/ISP 日志；取帧失败不一定是物理断连。',
    'MEDIA_INITIALIZATION_FAILED' ||
    'FLIGHT_CONTROL_FAILED' => '检查存储空间、录像权限、VENC/VB 资源及唤醒日志。',
    'CONFIGURATION_INVALID' => '检查配置 JSON，修正后重新启动。',
    'UART_OPEN_FAILED' => '检查串口设备节点、引脚复用及端口占用。',
    'WORKER_READY_TIMEOUT' => '检查 UART 握手、相机初始化和 worker 日志。',
    'WORKER_SIGNALLED' => '查看信号编号与内核/OOM/崩溃日志，不能仅凭信号判断原因。',
    _ => hint.isEmpty ? '请查看板端 worker 日志。' : hint,
  };

  String get details => [
    code,
    if (stage.isNotEmpty) 'stage=$stage',
    if (exitCode != null) 'exit=$exitCode',
    if (signal != null) 'signal=$signal',
    if (nativeCode != null && nativeCode != 0)
      'native=$nativeCode (0x${nativeCode!.toUnsigned(32).toRadixString(16)})',
    if (message.isNotEmpty) message,
  ].join('\n');
}
