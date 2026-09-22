import 'package:flutter/material.dart';

import 'package:dart_control_panel/controllers/board_session.dart';
import 'package:dart_control_panel/widgets/connection_bar.dart';

/// Global connection dock laid out below every page (never over its content).
///
/// Disconnected: board address + Connect. TCP control always uses port 9000.
/// Connected: status chip +
/// endpoint + Disconnect. The dock is the ONLY place a connection is
/// started/stopped — switching pages never touches the session.
class ConnectionDock extends StatelessWidget {
  const ConnectionDock({
    super.key,
    required this.session,
    required this.hostController,
    required this.onConnect,
    required this.onDisconnect,
  });

  final BoardSession session;
  final TextEditingController hostController;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final connected = session.connected;
        return Card(
          margin: EdgeInsets.zero,
          elevation: 4,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (session.busy || session.connecting)
                  const LinearProgressIndicator(minHeight: 2),
                if (connected)
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (session.connection != null)
                        ConnectionStatusChip(connection: session.connection!),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 240),
                        child: Text(
                          session.host,
                          style: Theme.of(context).textTheme.bodySmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Disconnect',
                        onPressed: onDisconnect,
                        icon: const Icon(Icons.link_off, size: 18),
                      ),
                    ],
                  )
                else
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: hostController,
                          onSubmitted: (_) => onConnect(),
                          decoration: const InputDecoration(
                            labelText: 'Board IP',
                            hintText: '10.149.242.1',
                            prefixIcon: Icon(Icons.router_outlined),
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed: session.connecting ? null : onConnect,
                        icon: const Icon(Icons.link),
                        label: const Text('Connect'),
                      ),
                    ],
                  ),
                if (session.statusError && session.statusMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 340),
                      child: Text(
                        session.statusMessage!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.error,
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 2,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
