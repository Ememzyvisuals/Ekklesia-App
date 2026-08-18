import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/config/app_theme.dart';
import '../../../core/services/download_worker.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../domain/download_task.dart';

/// Downloads management screen — the UI half of the download engine that
/// already existed in core/services/download_worker.dart. Shows every
/// queued/active/completed/failed task with pause/resume/retry/delete and
/// a running storage total.
///
/// Honest scope note: nothing in the app calls
/// `DownloadWorker.instance.enqueue(...)` yet outside of the one entry
/// point wired in ai_assistant_screen.dart (saving a generated prayer/
/// verse reading as offline audio). Sermon downloads aren't wired here —
/// video_player_screen.dart plays via youtube_player_flutter (an embedded
/// iframe player), which doesn't expose a direct file URL to download
/// from, and the YouTube Data API doesn't provide one either (downloading
/// video content outside the player violates YouTube's ToS). A real
/// "download this sermon for offline" feature needs its own audio-only
/// source (e.g. the DCLM radio archive, if one exists) — that's a
/// product question, not something to fake here with a fabricated URL.
class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  List<DownloadTask> _tasks = [];
  int _storageBytes = 0;
  bool _loading = true;
  final Map<String, StreamSubscription<DownloadTask>> _subs = {};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    for (final sub in _subs.values) {
      sub.cancel();
    }
    super.dispose();
  }

  Future<void> _refresh() async {
    final tasks = await DownloadWorker.instance.getAll();
    final storage = await DownloadWorker.instance.storageStatsBytes();
    if (!mounted) return;
    setState(() {
      _tasks = tasks..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      _storageBytes = storage;
      _loading = false;
    });
    _subscribeToActive();
  }

  /// Live-updates progress bars for anything currently downloading without
  /// polling the whole list — DownloadWorker's progressStream is per-task.
  void _subscribeToActive() {
    for (final task in _tasks) {
      if (task.status != DownloadStatus.downloading) continue;
      if (_subs.containsKey(task.id)) continue;
      _subs[task.id] =
          DownloadWorker.instance.progressStream(task.id).listen((updated) {
        if (!mounted) return;
        setState(() {
          final index = _tasks.indexWhere((t) => t.id == updated.id);
          if (index >= 0) _tasks[index] = updated;
        });
        if (updated.status != DownloadStatus.downloading) {
          _subs.remove(task.id)?.cancel();
          _refresh(); // storage total changed once a download completes
        }
      });
    }
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 MB';
    final mb = bytes / (1024 * 1024);
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    return '${(mb / 1024).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(AppLocalizations.of(context).downloadsTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text(
                      AppLocalizations.of(context)
                          .downloadsStorageUsed(_formatBytes(_storageBytes)),
                      style: const TextStyle(
                          color: AppTheme.textSecondary(context), fontSize: 13),
                    ),
                  ),
                  if (_tasks.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 48),
                      child: Center(
                        child: Text(
                          AppLocalizations.of(context).downloadsEmpty,
                          textAlign: TextAlign.center,
                          style:
                              TextStyle(color: AppTheme.textSecondary(context)),
                        ),
                      ),
                    )
                  else
                    ..._tasks.map(_buildTile),
                ],
              ),
            ),
    );
  }

  Widget _buildTile(DownloadTask task) {
    return ListTile(
      leading: _statusIcon(task.status),
      title: Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: _buildSubtitle(task),
      trailing: _buildActions(task),
    );
  }

  Widget _statusIcon(DownloadStatus status) {
    switch (status) {
      case DownloadStatus.completed:
        return const Icon(Icons.check_circle, color: Colors.green);
      case DownloadStatus.downloading:
        return const Icon(Icons.downloading, color: AppColors.primary);
      case DownloadStatus.paused:
        return const Icon(Icons.pause_circle_outline,
            color: AppTheme.textSecondary(context));
      case DownloadStatus.failed:
        return const Icon(Icons.error_outline, color: Colors.red);
      case DownloadStatus.queued:
        return const Icon(Icons.schedule, color: AppTheme.textSecondary(context));
    }
  }

  Widget _buildSubtitle(DownloadTask task) {
    switch (task.status) {
      case DownloadStatus.downloading:
        return LinearProgressIndicator(
            value: task.totalBytes > 0 ? task.progress : null);
      case DownloadStatus.failed:
        return Text(
          task.errorMessage ?? 'Failed',
          style: const TextStyle(color: Colors.red, fontSize: 12),
        );
      case DownloadStatus.completed:
        return Text(_formatBytes(task.totalBytes));
      case DownloadStatus.paused:
        return Text(
            'Paused · ${_formatBytes(task.downloadedBytes)} of ${_formatBytes(task.totalBytes)}');
      case DownloadStatus.queued:
        return const Text('Queued');
    }
  }

  Widget _buildActions(DownloadTask task) {
    switch (task.status) {
      case DownloadStatus.downloading:
        return IconButton(
          icon: const Icon(Icons.pause),
          onPressed: () => DownloadWorker.instance.pause(task.id),
        );
      case DownloadStatus.paused:
      case DownloadStatus.queued:
        return IconButton(
          icon: const Icon(Icons.play_arrow),
          onPressed: () async {
            await DownloadWorker.instance.resume(task.id);
            _subscribeToActive();
          },
        );
      case DownloadStatus.failed:
        return IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: () async {
            await DownloadWorker.instance.retry(task.id);
            _subscribeToActive();
          },
        );
      case DownloadStatus.completed:
        return IconButton(
          icon: const Icon(Icons.delete_outline, color: Colors.red),
          onPressed: () async {
            await DownloadWorker.instance.delete(task.id);
            _refresh();
          },
        );
    }
  }
}
