import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:dart_control_panel/core/platform/app_paths.dart';

/// Android SAF content:// URIs are not dart:io directory paths. Keep recordings
/// in app-owned storage instead of asking for broad storage permissions.
Future<String?> chooseLogDirectory(
  BuildContext context, {
  String? initialDirectory,
  String? confirmButtonText,
}) async {
  if (!Platform.isAndroid) {
    return getDirectoryPath(
      initialDirectory: initialDirectory,
      confirmButtonText: confirmButtonText,
    );
  }
  return showDialog<String>(
    context: context,
    builder: (_) => _AndroidDirectoryPicker(
      initial: initialDirectory,
      label: confirmButtonText,
    ),
  );
}

class _AndroidDirectoryPicker extends StatefulWidget {
  const _AndroidDirectoryPicker({this.initial, this.label});
  final String? initial, label;
  @override
  State<_AndroidDirectoryPicker> createState() =>
      _AndroidDirectoryPickerState();
}

class _AndroidDirectoryPickerState extends State<_AndroidDirectoryPicker> {
  late final Directory root = AppPaths.dataRoot.absolute;
  late Directory current =
      widget.initial != null &&
          (widget.initial == root.path ||
              widget.initial!.startsWith('${root.path}/'))
      ? Directory(widget.initial!)
      : root;
  final field = TextEditingController();
  List<Directory> dirs = [];
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    field.dispose();
    super.dispose();
  }

  Future<void> load() async {
    try {
      await current.create(recursive: true);
      final values = await current
          .list(followLinks: false)
          .where((e) => e is Directory)
          .cast<Directory>()
          .toList();
      values.sort((a, b) => a.path.compareTo(b.path));
      if (mounted) {
        setState(() {
          dirs = values;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> create() async {
    final name = field.text.trim();
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains('\\')) {
      return;
    }
    try {
      await Directory('${current.path}/$name').create();
      field.clear();
      await load();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('选择应用日志目录'),
    content: SizedBox(
      width: 600,
      height: 250,
      child: Column(
        children: [
          const Text('Android 日志保存在本应用专用目录，不需要“所有文件访问”权限。'),
          SelectableText(current.path, maxLines: 2),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          Expanded(
            child: ListView(
              children: [
                if (current.path != root.path)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.arrow_upward),
                    title: const Text('上一级'),
                    onTap: () {
                      current = current.parent;
                      load();
                    },
                  ),
                for (final dir in dirs)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.folder),
                    title: Text(dir.path.split('/').last),
                    onTap: () {
                      current = dir;
                      load();
                    },
                  ),
              ],
            ),
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: field,
                  decoration: const InputDecoration(hintText: '新建子目录'),
                  onSubmitted: (_) => create(),
                ),
              ),
              IconButton(
                onPressed: create,
                icon: const Icon(Icons.create_new_folder),
              ),
            ],
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: error == null
            ? () => Navigator.pop(context, current.path)
            : null,
        child: Text(widget.label ?? '选择此目录'),
      ),
    ],
  );
}
