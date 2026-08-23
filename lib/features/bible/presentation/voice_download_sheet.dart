import 'package:flutter/material.dart';

import '../../../core/config/app_config.dart';
import '../../../core/config/app_theme.dart';
import '../../../core/services/tts_model_registry.dart';

/// PROJECT_MIGRATION_AUDIT.md Phase 5 — the model picker requested
/// explicitly: users see a list of downloadable voices, pick which to
/// download, see progress, and can delete a downloaded voice — same
/// pattern any on-device AI app uses, rather than an auto-download
/// happening silently in the background.
///
/// [mmsCode] is optional: pass it when opened from a specific "this
/// language needs a voice" prompt (bible_screen.dart's
/// TtsModelNotReadyException handler) to highlight that entry and
/// auto-close once it's ready; omit it to show the full picker (e.g.
/// from Settings).
class VoiceDownloadSheet extends StatefulWidget {
  const VoiceDownloadSheet({super.key, this.mmsCode});

  final String? mmsCode;

  @override
  State<VoiceDownloadSheet> createState() => _VoiceDownloadSheetState();
}

class _VoiceDownloadSheetState extends State<VoiceDownloadSheet> {
  final Map<String, TtsModelInfo> _status = {};

  @override
  void initState() {
    super.initState();
    for (final code in AppConfig.mmsOnnxAvailableLanguages) {
      _refreshStatus(code);
    }
  }

  Future<void> _refreshStatus(String mmsCode) async {
    final info = await TtsModelRegistry.instance.status(mmsCode);
    if (mounted) setState(() => _status[mmsCode] = info);
  }

  void _download(String mmsCode) {
    TtsModelRegistry.instance.ensureDownloaded(mmsCode).listen((info) {
      if (!mounted) return;
      setState(() => _status[mmsCode] = info);
      if (info.isReady && widget.mmsCode == mmsCode) {
        // The voice this sheet was opened for just finished — let the
        // caller (bible_screen.dart) know it can retry playback.
        Navigator.of(context).pop(true);
      }
    });
  }

  Future<void> _delete(String mmsCode) async {
    await TtsModelRegistry.instance.remove(mmsCode);
    await _refreshStatus(mmsCode);
  }

  String _label(String mmsCode) => switch (mmsCode) {
        'yor' => 'Yoruba',
        'hau' => 'Hausa',
        'pcm' => 'Nigerian Pidgin',
        _ => mmsCode,
      };

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Offline voices',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              'Downloaded once, then works with no internet connection. '
              'Voices are AI-generated and can mispronounce words or names. '
              'this is not a human reading.',
              style: TextStyle(
                  fontSize: 13, color: AppTheme.textSecondary(context)),
            ),
            const SizedBox(height: 16),
            for (final code in AppConfig.mmsOnnxAvailableLanguages)
              _VoiceRow(
                label: _label(code),
                info: _status[code],
                highlighted: widget.mmsCode == code,
                onDownload: () => _download(code),
                onDelete: () => _delete(code),
              ),
            const SizedBox(height: 8),
            Text(
              'Igbo has no offline voice available yet. See the app\'s '
              'migration notes for what was tried.',
              style: TextStyle(
                  fontSize: 12, color: AppTheme.textSecondary(context)),
            ),
          ],
        ),
      ),
    );
  }
}

class _VoiceRow extends StatelessWidget {
  const _VoiceRow({
    required this.label,
    required this.info,
    required this.highlighted,
    required this.onDownload,
    required this.onDelete,
  });

  final String label;
  final TtsModelInfo? info;
  final bool highlighted;
  final VoidCallback onDownload;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final status = info?.status ?? TtsModelDownloadStatus.notInstalled;

    Widget trailing;
    switch (status) {
      case TtsModelDownloadStatus.ready:
        trailing = IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Remove downloaded voice',
          onPressed: onDelete,
        );
      case TtsModelDownloadStatus.downloading:
        final progress = info?.downloadProgress;
        trailing = SizedBox(
          width: 48,
          child: progress == null
              ? const LinearProgressIndicator()
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LinearProgressIndicator(value: progress),
                    Text('${(progress * 100).round()}%',
                        style: const TextStyle(fontSize: 10)),
                  ],
                ),
        );
      case TtsModelDownloadStatus.error:
        trailing = TextButton(
          onPressed: onDownload,
          child: const Text('Retry'),
        );
      case TtsModelDownloadStatus.notInstalled:
        trailing = FilledButton.tonal(
          onPressed: onDownload,
          child: const Text('Download'),
        );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        border: highlighted
            ? Border.all(color: AppColors.accent, width: 1.5)
            : Border.all(color: Colors.transparent),
        borderRadius: BorderRadius.circular(12),
        color: AppTheme.surface(context),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                if (status == TtsModelDownloadStatus.error &&
                    info?.errorMessage != null)
                  Text(
                    info!.errorMessage!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: Colors.red),
                  ),
              ],
            ),
          ),
          trailing,
        ],
      ),
    );
  }
}
