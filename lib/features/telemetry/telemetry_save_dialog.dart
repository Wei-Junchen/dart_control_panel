import 'dart:io';
import 'package:flutter/material.dart';
import 'package:dart_control_panel/shared/widgets/log_directory_picker.dart';
import 'package:dart_control_panel/core/preferences/telemetry_log_settings.dart';
import 'telemetry_controller.dart';
import 'telemetry_chart.dart';
import 'telemetry_recording_controls.dart';

Future<void> showTelemetrySaveDialog(
  BuildContext context,
  TelemetryController controller,
) async {
  if (controller.pendingRecording == null) return;
  await controller.prepareSave();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _SaveDialog(controller: controller),
  );
}

class _SaveDialog extends StatefulWidget {
  const _SaveDialog({required this.controller});
  final TelemetryController controller;
  @override
  State<_SaveDialog> createState() => _SaveDialogState();
}

class _SaveDialogState extends State<_SaveDialog> {
  late final _directory = TextEditingController(
    text:
        widget.controller.recorder?.directory.path ??
        widget.controller.pendingRecording?.parent.path ??
        '',
  );
  late final _name = TextEditingController(
    text: widget.controller.recorder?.settings.name ?? '日志',
  );
  late final _tags = TextEditingController(
    text: widget.controller.recorder?.settings.tags.join(', ') ?? '',
  );
  bool _remember = true;
  @override
  void dispose() {
    _directory.dispose();
    _name.dispose();
    _tags.dispose();
    super.dispose();
  }

  bool _busy = false;
  String? _error;
  Future<void> _choose(bool save, bool trim) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final tags = TelemetryLogSettings.parseTags(_tags.text);
      if (save && _directory.text.trim().isEmpty) {
        throw ArgumentError('请选择保存目录');
      }
      if (save && _remember) {
        await widget.controller.recorder?.updateSettings(
          TelemetryLogSettings(
            directory: _directory.text.trim(),
            name: _name.text.trim(),
            tags: tags,
          ),
        );
      }
      await widget.controller.decideRecording(
        save: save,
        trim: trim,
        destination: save ? Directory(_directory.text.trim()).absolute : null,
        name: _name.text,
        tags: tags,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    child: AlertDialog(
      scrollable: true,
      title: const Text('保存接收日志'),
      content: SizedBox(
        width: 1000,
        height: (MediaQuery.sizeOf(context).height - 200).clamp(480.0, 700.0),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('log-save-directory'),
                    controller: _directory,
                    enabled: !_busy,
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: '保存目录',
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '选择保存目录',
                  onPressed: _busy
                      ? null
                      : () async {
                          final path = await chooseLogDirectory(
                            context,
                            initialDirectory: _directory.text,
                          );
                          if (path != null && mounted) _directory.text = path;
                        },
                  icon: const Icon(Icons.folder_open),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('log-save-name'),
                    controller: _name,
                    enabled: !_busy,
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: '日志名称',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    key: const ValueKey('log-save-tags'),
                    controller: _tags,
                    enabled: !_busy,
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: '标签（逗号分隔）',
                    ),
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Checkbox(
                  value: _remember,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _remember = v!),
                ),
                const Flexible(
                  child: Text(
                    '记住目录、名称和标签，下次启动默认使用',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
            const Text(
              '按 月日时分_名称 归档，完整时间 metadata 保留。',
              style: TextStyle(fontSize: 12),
            ),
            Expanded(child: TelemetryChart(controller: widget.controller)),
            TelemetryRecordingControls(
              controller: widget.controller,
              timeline: true,
              saveEditor: true,
            ),
            if (_error != null)
              Text(_error!, style: const TextStyle(color: Colors.red)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => _choose(false, false),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: _busy ? null : () => _choose(true, true),
          child: const Text('保存选区'),
        ),
        FilledButton(
          onPressed: _busy ? null : () => _choose(true, false),
          child: const Text('保存完整日志'),
        ),
      ],
    ),
  );
}
