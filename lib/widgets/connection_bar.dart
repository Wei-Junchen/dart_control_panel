import 'package:flutter/material.dart';

import 'package:dart_control_panel/controllers/connection_controller.dart';

/// P2 connection bar (host/port + connect/disconnect) — kept presentational
/// and public so the shell screen stays thin and tests can drive it.
class ConnectionBar extends StatelessWidget {
  const ConnectionBar({
    super.key,
    required this.hostController,
    required this.portController,
    required this.connected,
    required this.lastError,
    required this.onConnect,
    required this.onDisconnect,
  });

  final TextEditingController hostController;
  final TextEditingController portController;
  final bool connected;
  final String? lastError;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: hostController,
                  enabled: !connected,
                  decoration: const InputDecoration(
                    labelText: 'Board address',
                    prefixIcon: Icon(Icons.router),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 90,
                child: TextField(
                  controller: portController,
                  enabled: !connected,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Port',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: connected ? onDisconnect : onConnect,
                icon: Icon(connected ? Icons.link_off : Icons.link),
                label: Text(connected ? 'Disconnect' : 'Connect'),
              ),
            ],
          ),
          if (lastError != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber, size: 16, color: Colors.orange),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      lastError!,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: Colors.orange),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// P2 connection status chip (connected / connecting / reconnecting /
/// disconnected).
class ConnectionStatusChip extends StatelessWidget {
  const ConnectionStatusChip({super.key, required this.connection});

  final ConnectionController connection;

  @override
  Widget build(BuildContext context) {
    final (color, text) = switch (connection.status) {
      BoardConnectionStatus.connected => (Colors.green, 'connected'),
      BoardConnectionStatus.connecting => (Colors.amber, 'connecting'),
      BoardConnectionStatus.reconnecting => (Colors.orange, 'reconnecting'),
      BoardConnectionStatus.disconnected => (Colors.grey, 'disconnected'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12),
      ),
    );
  }
}
