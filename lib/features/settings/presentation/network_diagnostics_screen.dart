import 'package:flutter/material.dart';

import '../../../core/config/app_theme.dart';
import '../../../core/services/network_diagnostics.dart';

/// A debugging tool, not a user-facing feature — reached from Settings,
/// runs real network calls against every actual endpoint this app
/// depends on, and shows the exact, unfiltered result of each (unlike
/// every other error surface in the app, which deliberately shows
/// friendly, simplified messages instead of raw exception text). Exists
/// specifically so that if "the app acts like it's offline" happens
/// again, there's exact evidence to look at — which specific dependency
/// failed and with what error — rather than another round of guessing.
class NetworkDiagnosticsScreen extends StatefulWidget {
  const NetworkDiagnosticsScreen({super.key});

  @override
  State<NetworkDiagnosticsScreen> createState() =>
      _NetworkDiagnosticsScreenState();
}

class _NetworkDiagnosticsScreenState extends State<NetworkDiagnosticsScreen> {
  final List<DiagnosticResult> _results = [];
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() {
      _results.clear();
      _running = true;
    });
    await for (final result in NetworkDiagnostics.instance.runAll()) {
      if (!mounted) return;
      setState(() => _results.add(result));
    }
    if (mounted) setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Network Diagnostics'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _running ? null : _run,
            tooltip: 'Run again',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.surface(context),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              'This runs a real network request against each service the '
              'app actually uses, one at a time, and shows the exact '
              'result, including the raw error text a normal error '
              'message would otherwise hide. Useful for reporting a '
              '"seems offline" issue precisely.',
              style: TextStyle(
                  fontSize: 13, color: AppTheme.textSecondary(context)),
            ),
          ),
          const SizedBox(height: 16),
          for (final result in _results) _ResultTile(result: result),
          if (_running)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({required this.result});
  final DiagnosticResult result;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surface(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: (result.ok ? Colors.green : Colors.red).withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            result.ok ? Icons.check_circle : Icons.error,
            color: result.ok ? Colors.green : Colors.red,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        result.name,
                        style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textPrimary(context)),
                      ),
                    ),
                    Text('${result.durationMs}ms',
                        style: TextStyle(
                            fontSize: 11,
                            color: AppTheme.textSecondary(context))),
                  ],
                ),
                const SizedBox(height: 4),
                SelectableText(
                  result.detail,
                  style: TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      color: result.ok
                          ? AppTheme.textSecondary(context)
                          : Colors.red[300]),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
