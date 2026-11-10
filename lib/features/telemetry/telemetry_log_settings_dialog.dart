import 'package:flutter/material.dart';
import 'package:dart_control_panel/shared/widgets/log_directory_picker.dart';
import 'package:dart_control_panel/core/preferences/telemetry_log_settings.dart';
import 'telemetry_archive.dart';

Future<void> showTelemetryLogSettings(
  BuildContext context,
  TelemetryRecorder recorder,
) async {
  await showDialog<void>(
    context: context,
    builder: (_) => _SettingsDialog(recorder: recorder),
  );
}

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog({required this.recorder});
  final TelemetryRecorder recorder;
  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  late final _path = TextEditingController(
    text: widget.recorder.directory.path,
  );
  late final _name = TextEditingController(text: widget.recorder.settings.name);
  late final _tags = TextEditingController(
    text: widget.recorder.settings.tags.join(', '),
  );
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _path.dispose();
    _name.dispose();
    _tags.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_path.text.trim().isEmpty) throw ArgumentError('请选择保存目录');
      await widget.recorder.updateSettings(
        TelemetryLogSettings(
          directory: _path.text.trim(),
          name: _name.text.trim(),
          tags: TelemetryLogSettings.parseTags(_tags.text),
        ),
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('日志默认配置'),
    content: SizedBox(
      width: 540,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _path,
                  decoration: const InputDecoration(labelText: '保存目录'),
                ),
              ),
              IconButton(
                tooltip: '选择目录',
                onPressed: _busy
                    ? null
                    : () async {
                        final path = await chooseLogDirectory(
                          context,
                          initialDirectory: _path.text,
                        );
                        if (path != null && mounted) _path.text = path;
                      },
                icon: const Icon(Icons.folder_open),
              ),
            ],
          ),
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: '默认日志名称'),
          ),
          TextField(
            controller: _tags,
            decoration: const InputDecoration(labelText: '默认标签（逗号分隔）'),
          ),
          const SizedBox(height: 12),
          const Text('配置持久化，下次启动自动加载。当前记录不会迁移，下一段使用新目录。'),
          if (_error != null)
            Text(_error!, style: const TextStyle(color: Colors.red)),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _busy ? null : _save,
        child: const Text('保存默认配置'),
      ),
    ],
  );
}
