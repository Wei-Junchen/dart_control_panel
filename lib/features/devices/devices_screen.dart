import 'package:flutter/material.dart';

import 'package:dart_control_panel/core/board/session/board_session.dart';
import 'package:dart_control_panel/core/preferences/device_registry.dart';

bool isCurrentDevice(BoardSession session, DeviceRecord record) =>
    session.connected && session.state?.device.deviceId == record.deviceId;

bool canConnectDevice(BoardSession session, DeviceRecord record) =>
    !isCurrentDevice(session, record) && !session.connecting && !session.busy;

class DevicesScreen extends StatelessWidget {
  const DevicesScreen({
    super.key,
    required this.registry,
    required this.session,
    required this.onConnect,
    required this.onOpenLogs,
    this.onOpenAllLogs,
    this.onOpenUnknownLogs,
  });

  final DeviceRegistry registry;
  final BoardSession session;
  final void Function(String host, int port) onConnect;
  final void Function(DeviceRecord record) onOpenLogs;
  final VoidCallback? onOpenAllLogs;
  final VoidCallback? onOpenUnknownLogs;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([registry, session]),
      builder: (context, _) {
        final records = registry.load();
        return Scaffold(
          appBar: AppBar(title: const Text('设备管理')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const SizedBox(height: 6),
              Text(
                '本地飞行记录和遥测会话按 device_id 分目录保存；SN 只作为显示名称。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              if (onOpenAllLogs != null) ...[
                Card(
                  child: ListTile(
                    key: const ValueKey('all-flight-logs'),
                    leading: const Icon(Icons.folder_open),
                    title: const Text('全部本地飞行记录'),
                    subtitle: const Text('包括旧版本未关联设备的记录'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: onOpenAllLogs,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (onOpenUnknownLogs != null) ...[
                Card(
                  child: ListTile(
                    key: const ValueKey('unknown-device'),
                    leading: const Icon(Icons.device_unknown_outlined),
                    title: const Text('unknown'),
                    subtitle: const Text('未绑定设备或身份不可用的记录；可能来自多台板子'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: onOpenUnknownLogs,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (records.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('尚无已登记设备。连接板子后会自动记录 device_id 和 SN。'),
                  ),
                )
              else
                Card(
                  child: Column(
                    children: [
                      for (final record in records)
                        _deviceTile(context, record),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _deviceTile(BuildContext context, DeviceRecord record) {
    final current = isCurrentDevice(session, record);
    final connectable = canConnectDevice(session, record);
    return ListTile(
      leading: Icon(
        current
            ? Icons.link
            : record.status == 'READY'
            ? Icons.memory
            : Icons.warning_amber,
        color: current ? Theme.of(context).colorScheme.primary : null,
      ),
      title: Text('${record.label} · ${record.status}'),
      subtitle: Text(
        'device_id: ${record.deviceId}\n'
        '最后地址: ${record.host ?? '未知'}:${record.port}\n'
        '最后连接: ${record.lastSeen?.toLocal() ?? '未知'}\n'
        '点击查看本地日志',
      ),
      isThreeLine: true,
      onTap: () => onOpenLogs(record),
      trailing: Wrap(
        spacing: 4,
        children: [
          if (record.host != null)
            TextButton.icon(
              onPressed: connectable
                  ? () => onConnect(record.host!, record.port)
                  : null,
              icon: Icon(current ? Icons.check : Icons.link, size: 18),
              label: Text(current ? '已连接' : '连接'),
            ),
          IconButton(
            tooltip: '从设备列表移除（不删除本地记录）',
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text('移除 ${record.label}？'),
                  content: const Text('只移除本机设备索引，不删除任何飞行记录、遥测或板端文件。'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('移除'),
                    ),
                  ],
                ),
              );
              if (confirmed == true) {
                await registry.remove(record.deviceId);
              }
            },
            icon: const Icon(Icons.delete_outline, size: 18),
          ),
        ],
      ),
    );
  }
}
