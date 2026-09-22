import 'package:flutter/material.dart';

import 'package:dart_control_panel/controllers/connection_controller.dart';

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
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w600,
          fontSize: 12,
        ),
      ),
    );
  }
}
