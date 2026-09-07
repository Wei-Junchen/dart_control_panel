import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'package:dart_control_panel/controllers/file_controller.dart';
import 'package:dart_control_panel/services/board_ssh.dart';

/// 文件传输页：浏览板端文件（ssh），双击/按钮 scp 下载到本地；
/// 本地选文件 scp 上传到板端。
/// 认证：密钥（默认）或 用户名+密码（`sshpass`，密码仅内存、不持久化）。
class FilesScreen extends StatefulWidget {
  const FilesScreen({super.key, required this.host, this.controller});

  final String host;

  /// Injectable for tests.
  final FileController? controller;

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  String _user =
      Platform.environment['DART_CTRL_SSH_USER']?.trim().isNotEmpty == true
          ? Platform.environment['DART_CTRL_SSH_USER']!
          : 'root';
  String? _password;
  late FileController _controller = widget.controller ??
      FileController(
        ssh: BoardSshImpl(widget.host, user: _user, password: _password),
      );
  final TextEditingController _pathField = TextEditingController(text: '/');
  final TextEditingController _userField =
      TextEditingController(text: 'root');
  final TextEditingController _passwordField =
      TextEditingController(text: '');

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    _controller.init();
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _pathField.dispose();
    _userField.dispose();
    _passwordField.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) {
      _pathField.text = _controller.path;
      setState(() {});
    }
  }

  /// Rebuilds the controller with new credentials. The password stays in
  /// [TextEditingController]_memory only — never written to disk.
  void _recreateController() {
    _controller.removeListener(_onChanged);
    _user = _userField.text.trim().isEmpty ? 'root' : _userField.text.trim();
    final pwd = _passwordField.text;
    _password = pwd.isEmpty ? null : pwd;
    final fresh = widget.controller ??
        FileController(
          ssh: BoardSshImpl(widget.host, user: _user, password: _password),
        );
    setState(() => _controller = fresh);
    _controller.addListener(_onChanged);
    _controller.init();
  }

  Future<void> _openAuthDialog() async {
    _userField.text = _user;
    _passwordField.text = _password ?? '';
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('SSH 认证'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _userField,
              decoration: const InputDecoration(
                labelText: '用户名',
                helperText: '默认 root',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _passwordField,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '密码',
                helperText: '留空 = 使用本机 SSH 密钥；密码仅本次会话有效，不会保存',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              _recreateController();
              Navigator.pop(context);
            },
            child: const Text('保存并连接'),
          ),
        ],
      ),
    );
  }

  Future<void> _goTo(String path) async {
    _pathField.text = path;
    await _controller.cd(path);
  }

  Future<void> _download(RemoteEntry entry) async {
    final dir = await getDirectoryPath();
    if (dir == null) return;
    await _controller.download(entry, dir);
    _showStatus('Downloaded ${entry.name} → $dir');
  }

  Future<void> _upload() async {
    final file = await openFile();
    if (file == null) return;
    await _controller.upload(file.path);
    _showStatus('Uploaded ${file.name} → ${_controller.path}');
  }

  void _showStatus(String okMessage) {
    if (!mounted) return;
    final error = _controller.error;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(error ?? okMessage),
      backgroundColor: error != null ? Colors.red.shade300 : null,
      duration: const Duration(seconds: 4),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Files — ${widget.host} (ssh/scp)'),
        actions: [
          IconButton(
            tooltip: 'SSH 认证设置',
            icon: const Icon(Icons.key_outlined),
            onPressed: _openAuthDialog,
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              _controller.probe();
              _controller.refresh();
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          _pathBar(context),
          ?_errorBanner(context),
          Expanded(child: _fileList(context)),
        ],
      ),
    );
  }

  Widget _pathBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                tooltip: 'Up',
                icon: const Icon(Icons.arrow_upward),
                onPressed: _controller.path != '/' ? _controller.up : null,
              ),
              Expanded(
                child: TextField(
                  controller: _pathField,
                  decoration: const InputDecoration(
                    labelText: 'Remote path',
                    isDense: true,
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.folder, size: 18),
                  ),
                  onSubmitted: (v) => _goTo(v.trim()),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _controller.loading ? null : _controller.refresh,
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('Go'),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: 'Test SSH',
                icon: Icon(
                  Icons.wifi_tethering,
                  color: _controller.sshReady ? Colors.green : Colors.grey,
                ),
                onPressed: () async {
                  await _controller.probe();
                  await _controller.refresh();
                  if (mounted) {
                    _showStatus(_controller.sshReady ? 'SSH OK' : 'SSH failed');
                  }
                },
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: 'Bookmark this path',
                icon: const Icon(Icons.bookmark_add_outlined),
                onPressed: _controller.addBookmark,
              ),
              const SizedBox(width: 4),
              FilledButton.icon(
                onPressed: _controller.busy ? null : _upload,
                icon: const Icon(Icons.upload),
                label: const Text('Upload'),
              ),
            ],
          ),
          if (_controller.bookmarks.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final b in _controller.bookmarks)
                    InputChip(
                      label: Text(b),
                      onPressed: () => _goTo(b),
                      onDeleted: b.startsWith('/release')
                          ? null
                          : () => _controller.removeBookmark(b),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget? _errorBanner(BuildContext context) {
    final error = _controller.error;
    final hint = _controller.sshHint();
    if (error == null && hint == null) return null;
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hint != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                hint,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                  fontWeight: FontWeight.bold,
                ),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (error != null)
            Text(
              error,
              style:
                  TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }

  Widget _fileList(BuildContext context) {
    if (_controller.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final entries = _controller.entries;
    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        return ListTile(
          dense: true,
          leading: Icon(
            entry.isDir ? Icons.folder : Icons.insert_drive_file,
            color: entry.isDir ? Colors.amber[700] : Colors.blueGrey[300],
          ),
          title: Text(
            entry.isDir && !entry.name.endsWith('/')
                ? '${entry.name}/'
                : entry.name,
          ),
          subtitle: Text(
            entry.isDir
                ? entry.modified
                : '${_humanSize(entry.size)} · ${entry.modified}'
                    '${entry.linkTarget != null ? ' -> ${entry.linkTarget}' : ''}',
          ),
          trailing: entry.isDir
              ? null
              : IconButton(
                  tooltip: 'Download',
                  icon: Icon(
                    Icons.download,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  onPressed:
                      _controller.busy ? null : () => _download(entry),
                ),
          onTap: entry.isDir
              ? () => _goTo(
                  FileController.joinPath(_controller.path, entry.name))
              : null,
        );
      },
    );
  }

  String _humanSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1048576).toStringAsFixed(1)} MB';
  }
}