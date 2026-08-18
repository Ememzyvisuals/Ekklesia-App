import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/connectivity_monitor.dart';

/// Shows nothing at all while online — only appears as a slim strip
/// when the device genuinely has no raw internet connectivity, so it's
/// never visual noise, only ever a real signal. Directly answers "show
/// when I am online and offline" without cluttering every screen with a
/// permanent status widget.
class OfflineIndicator extends StatelessWidget {
  const OfflineIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: ConnectivityMonitor.instance.isOnlineStream,
      initialData: ConnectivityMonitor.instance.lastKnown,
      builder: (context, snapshot) {
        final online = snapshot.data ?? true;
        if (online) {
          return const SizedBox.shrink();
        }
        return Material(
          color: Colors.red[700],
          child: InkWell(
            onTap: () => context.push('/network-diagnostics'),
            child: const SafeArea(
              bottom: false,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.wifi_off, color: Colors.white, size: 14),
                    SizedBox(width: 6),
                    Text(
                      'No internet connection. Tap to diagnose.',
                      style: TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
