import 'dart:async';

import 'package:dart_control_panel/shared/widgets/log_directory_picker.dart';
import 'package:flutter/material.dart';

import 'package:dart_control_panel/features/files/file_controller.dart';
import 'package:dart_control_panel/core/video/video_controller.dart';
import 'package:dart_control_panel/features/files/board_file_api.dart';
import 'package:dart_control_panel/core/video/video_panel.dart';

/// Read-only board file page over HTTP: browse, resumable download, log tail
/// preview, and video playback. It never starts ssh/scp or reads known_hosts.
class FilesScreen extends StatefulWidget {
  const FilesScreen({
    super.key,
    required this.host,
    this.port = 9002,
    this.controller,
  });

  final String host;
  final int port;
  final FileController? controller;

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  late final FileController _controller =
      widget.controller ??
      FileController(api: HttpBoardFileApi(widget.host, port: widget.port));
  final TextEditingController _pathField = TextEditingController(text: '/');

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
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    _pathField.text = _controller.path;
    setState(() {});
  }

  Future<void> _goTo(String path) async {
    _pathField.text = path;
    await _controller.cd(path);
  }

  Future<void> _download(RemoteEntry entry) async {
    final dir = await chooseLogDirectory(context);
    if (dir == null) return;
    await _controller.download(entry, dir);
    _showStatus('Downloaded ${entry.name} → $dir');
  }

  bool _isText(RemoteEntry entry) {
    final n = entry.name.toLowerCase();
    return n.endsWith('.log') || n.endsWith('.txt') || n.endsWith('.json');
  }

  bool _isVideo(RemoteEntry entry) {
    final n = entry.name.toLowerCase();
    return n.endsWith('.h264') ||
        n.endsWith('.mp4') ||
        n.endsWith('.mkv') ||
        n.endsWith('.avi');
  }

  Future<void> _previewText(RemoteEntry entry) async {
    try {
      final text = await _controller.readText(entry);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${entry.name} · tail'),
          content: SizedBox(
            width: 900,
            height: 560,
            child: SingleChildScrollView(
              child: SelectableText(
                text,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (e) {
      _showStatus('Preview failed: $e');
    }
  }

  Future<void> _previewVideo(RemoteEntry entry) async {
    final player = VideoController();
    final url = _controller.downloadUri(entry).toString();
    unawaited(player.open(url));
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${entry.name} · ${_humanSize(entry.size)}'),
        content: SizedBox(
          width: 900,
          height: 600,
          child: VideoPanel(controller: player, rtspAvailable: true, url: url),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    await player.stop();
    player.dispose();
  }

  void _showStatus(String okMessage) {
    if (!mounted) return;
    final error = _controller.error;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error ?? okMessage),
        backgroundColor: error != null ? Colors.red.shade300 : null,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Files — ${_controller.boardLabel} (HTTP read-only)'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () async {
              await _controller.probe();
              await _controller.refresh();
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
                    labelText: 'Virtual path',
                    helperText: 'Only /logs and /recordings are exposed',
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
                tooltip: 'Test file service',
                icon: Icon(
                  Icons.wifi_tethering,
                  color: _controller.serviceReady ? Colors.green : Colors.grey,
                ),
                onPressed: () async {
                  await _controller.probe();
                  await _controller.refresh();
                  if (mounted) {
                    _showStatus(
                      _controller.serviceReady
                          ? 'File service OK · ${_controller.boardLabel}'
                          : 'File service unavailable',
                    );
                  }
                },
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: 'Bookmark this path',
                icon: const Icon(Icons.bookmark_add_outlined),
                onPressed: _controller.addBookmark,
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
                      onDeleted: b == '/' || b == '/logs' || b == '/recordings'
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
    final hint = _controller.serviceHint();
    if (error == null && hint == null) return null;
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hint != null)
            Text(
              hint,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onErrorContainer,
                fontWeight: FontWeight.bold,
              ),
            ),
          if (error != null) Text(error, maxLines: 3),
        ],
      ),
    );
  }

  Widget _fileList(BuildContext context) {
    if (_controller.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView.builder(
      itemCount: _controller.entries.length,
      itemBuilder: (context, index) {
        final entry = _controller.entries[index];
        return ListTile(
          dense: true,
          leading: Icon(
            entry.isDir ? Icons.folder : Icons.insert_drive_file,
            color: entry.isDir ? Colors.amber[700] : Colors.blueGrey[300],
          ),
          title: Text(entry.isDir ? '${entry.name}/' : entry.name),
          subtitle: Text(
            entry.isDir
                ? _formatTime(entry)
                : '${_humanSize(entry.size)} · ${_formatTime(entry)}',
          ),
          trailing: entry.isDir
              ? null
              : Wrap(
                  spacing: 2,
                  children: [
                    if (_isText(entry))
                      IconButton(
                        tooltip: 'Preview log tail',
                        icon: const Icon(Icons.article_outlined),
                        onPressed: () => _previewText(entry),
                      ),
                    if (_isVideo(entry))
                      IconButton(
                        tooltip: 'Play over HTTP',
                        icon: const Icon(Icons.play_circle_outline),
                        onPressed: () => _previewVideo(entry),
                      ),
                    IconButton(
                      tooltip: 'Download / resume',
                      icon: Icon(
                        Icons.download,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      onPressed: _controller.busy
                          ? null
                          : () => _download(entry),
                    ),
                  ],
                ),
          onTap: entry.isDir
              ? () => _goTo(entry.path)
              : _isText(entry)
              ? () => _previewText(entry)
              : _isVideo(entry)
              ? () => _previewVideo(entry)
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

  String _formatTime(RemoteEntry entry) {
    final time = entry.modified?.toLocal();
    if (time == null) return '-';
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }
}
