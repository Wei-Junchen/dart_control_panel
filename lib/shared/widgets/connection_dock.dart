import 'package:flutter/material.dart';

import 'package:dart_control_panel/core/board/session/board_session.dart';
import 'package:dart_control_panel/shared/widgets/connection_bar.dart';

/// Global connection dock laid out below every page (never over its content).
///
/// Disconnected: automatic AP discovery or advanced manual address/routing.
/// TCP control always uses port 9000.
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
    required this.automatic,
    required this.bindWifi,
    required this.discovering,
    required this.discoveryMessage,
    required this.onAutomaticChanged,
    required this.onBindWifiChanged,
  });

  final BoardSession session;
  final TextEditingController hostController;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;
  final bool automatic, bindWifi, discovering;
  final String discoveryMessage;
  final ValueChanged<bool> onAutomaticChanged;
  final ValueChanged<bool> onBindWifiChanged;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final connected = session.connected;
        final compact = MediaQuery.sizeOf(context).height < 500;
        final content = Card(
          margin: EdgeInsets.zero,
          elevation: 4,
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: 12,
              vertical: compact ? 2 : 8,
            ),
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
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(
                            value: true,
                            icon: Icon(Icons.wifi_find),
                            label: Text('自动连接'),
                          ),
                          ButtonSegment(
                            value: false,
                            icon: Icon(Icons.tune),
                            label: Text('高级连接'),
                          ),
                        ],
                        selected: {automatic},
                        onSelectionChanged: session.connecting
                            ? null
                            : (values) => onAutomaticChanged(values.single),
                      ),
                      const SizedBox(height: 6),
                      if (automatic) ...[
                        Text(
                          discoveryMessage,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 4),
                        FilledButton.icon(
                          onPressed: discovering || session.connecting
                              ? null
                              : onConnect,
                          icon: const Icon(Icons.wifi_find),
                          label: Text(discovering ? '正在自动连接…' : '自动连接'),
                        ),
                      ] else ...[
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: hostController,
                                keyboardType: TextInputType.url,
                                autocorrect: false,
                                enableSuggestions: false,
                                smartDashesType: SmartDashesType.disabled,
                                smartQuotesType: SmartQuotesType.disabled,
                                onSubmitted: (_) => onConnect(),
                                decoration: const InputDecoration(
                                  labelText: 'Board IP',
                                  hintText: '10.198.137.1',
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
                        SwitchListTile.adaptive(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: const Text('优先绑定 Wi-Fi（Android）'),
                          subtitle: const Text(
                            '关闭后使用系统路由，适用于中继 / VPN / 自定义路由表',
                          ),
                          value: bindWifi,
                          onChanged: session.connecting
                              ? null
                              : onBindWifiChanged,
                        ),
                      ],
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
        return compact
            ? Theme(
                data: Theme.of(context).copyWith(
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: content,
              )
            : content;
      },
    );
  }
}
