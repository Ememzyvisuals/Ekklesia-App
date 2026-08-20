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

  Future<void> _handleBack() async {
    // Many HTML5 games capture their own in-page navigation history —
    // without this check, the system back gesture/button can step
    // backward through the GAME's own pages first (or do nothing at
    // all if the game's own JS swallows the event) instead of actually
    // leaving the screen, which is exactly "no way back to Games" as
    // reported. Only pop the Flutter route once the WebView itself has
    // nowhere left to go back to.
    if (await _controller.canGoBack()) {
      await _controller.goBack();
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.title),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: 'Back to Games',
            onPressed: _handleBack,
          ),
        ),
        body: Stack(
          children: [
            WebViewWidget(controller: _controller),
            if (_loading) const Center(child: CircularProgressIndicator()),
          ],
        ),
      ),
    );
  }
}
