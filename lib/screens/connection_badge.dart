import 'package:flutter/material.dart';

import '../socket/haven_socket.dart';

/// AppBar indicator for the socket state.
class ConnectionBadge extends StatelessWidget {
  const ConnectionBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<WsStatus>(
      valueListenable: HavenSocket.instance.status,
      builder: (context, status, _) {
        final (color, label) = switch (status) {
          WsStatus.connected => (Colors.green, 'Live'),
          WsStatus.connecting => (Colors.orange, 'Connecting'),
          WsStatus.disconnected => (Colors.red, 'Offline'),
        };
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.circle, size: 10, color: color),
              const SizedBox(width: 6),
              Text(label, style: Theme.of(context).textTheme.labelMedium),
            ],
          ),
        );
      },
    );
  }
}
