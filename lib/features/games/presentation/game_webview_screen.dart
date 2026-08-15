import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Plays a game inside the app's WebView, from one of two sources:
/// - [url] set, [localIndexFilePath] null: a remote GameEntry.embedUrl —
///   only for entries where the publisher has explicitly permitted
///   embedding (see GamesScreen._openGame).
/// - [localIndexFilePath] set, [url] null: a user-imported local game
///   bundle's extracted index.html (see GameImportService) — loaded via
///   loadFile, so this path never touches the network at all.
/// Exactly one of the two is provided.
class GameWebViewScreen extends StatefulWidget {
  const GameWebViewScreen({
    super.key,
    required this.title,
    this.url,
    this.localIndexFilePath,
  }) : assert(
          (url != null) ^ (localIndexFilePath != null),
          'Provide exactly one of url or localIndexFilePath.',
        );

  final String title;
  final String? url;
  final String? localIndexFilePath;

  @override
  State<GameWebViewScreen> createState() => _GameWebViewScreenState();
}

class _GameWebViewScreenState extends State<GameWebViewScreen> {
  late final WebViewController _controller;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) => setState(() => _loading = true),
        onPageFinished: (_) => setState(() => _loading = false),
      ));
    final localPath = widget.localIndexFilePath;
    if (localPath != null) {
      _controller.loadFile(localPath);
    } else {
      _controller.loadRequest(Uri.parse(widget.url!));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_loading) const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}
