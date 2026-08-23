import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../../features/downloads/data/download_repository.dart';
import '../../features/downloads/domain/download_task.dart';
import 'notification_service.dart';

/// Foreground download engine: queue, pause, resume, retry, checksum,
/// delete, storage stats, progress — one task in flight at a time by
/// design (DCLM's radio/video hosts are not built for parallel-chunked
/// downloads, and a solo-dev v1 gains nothing from the added complexity
/// of a concurrent download pool with no evidence it's needed).
///
/// Scope note shared with every other worker in this file set: this runs
/// while the app is foregrounded. Background continuation while the app
/// is closed needs platform-registered background download support
/// (Android `WorkManager`/foreground service, iOS `URLSessionConfiguration
/// .background`) — not wired here; a large download will pause, not
/// silently corrupt, if the app is killed mid-transfer, since progress is
/// persisted after every chunk and resume uses an HTTP Range request.
class DownloadWorker {
  DownloadWorker._internal();
  static final DownloadWorker instance = DownloadWorker._internal();

  final Dio _dio = Dio();
  final _activeCancelTokens = <String, CancelToken>{};
  final _progressControllers = <String, StreamController<DownloadTask>>{};

  Stream<DownloadTask> progressStream(String taskId) {
    return _progressControllers
        .putIfAbsent(taskId, () => StreamController<DownloadTask>.broadcast())
        .stream;
  }

  Future<List<DownloadTask>> getAll() => DownloadRepository.instance.getAll();

  Future<DownloadTask> enqueue({
    required String title,
    required String sourceUrl,
    required String localPath,
    String? expectedSha256,
  }) async {
    final task = DownloadTask(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      title: title,
      sourceUrl: sourceUrl,
      localPath: localPath,
      expectedSha256: expectedSha256,
    );
    await DownloadRepository.instance.upsert(task);
    unawaited(start(task.id));
    return task;
  }

  Future<void> start(String taskId) async {
    final task = await _get(taskId);
    if (task == null) return;
    if (task.status == DownloadStatus.downloading) return; // already running

    final cancelToken = CancelToken();
    _activeCancelTokens[taskId] = cancelToken;

    final partFile = File('${task.localPath}.part');
    final resumeFrom = await partFile.exists() ? await partFile.length() : 0;

    task.status = DownloadStatus.downloading;
    task.downloadedBytes = resumeFrom;
    await _persist(task);

    try {
      await Directory(File(task.localPath).parent.path).create(recursive: true);
      final sink = partFile.openWrite(
        mode: resumeFrom > 0 ? FileMode.append : FileMode.write,
      );

      final response = await _dio.get<ResponseBody>(
        task.sourceUrl,
        options: Options(
          responseType: ResponseType.stream,
          headers: resumeFrom > 0 ? {'Range': 'bytes=$resumeFrom-'} : null,
        ),
        cancelToken: cancelToken,
      );

      final total = _resolveTotalBytes(response, resumeFrom);
      task.totalBytes = total;

      var received = resumeFrom;
      await for (final chunk in response.data!.stream) {
        sink.add(chunk);
        received += chunk.length;
        task.downloadedBytes = received;
        _progressControllers[taskId]?.add(task);
        // Persist periodically rather than on every chunk (chunk sizes from
        // Dio's stream are typically 8-16KB — persisting on every one of
        // those would hammer SharedPreferences for no real benefit).
        if (received % (256 * 1024) < chunk.length) {
          await _persist(task);
        }
      }
      await sink.close();

      await _finalize(task);
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        task.status = DownloadStatus.paused;
      } else {
        task.status = DownloadStatus.failed;
        task.errorMessage = e.message ?? 'Download failed';
      }
      await _persist(task);
    } catch (e) {
      task.status = DownloadStatus.failed;
      task.errorMessage = e.toString();
      await _persist(task);
    } finally {
      _activeCancelTokens.remove(taskId);
    }
  }

  Future<void> pause(String taskId) async {
    _activeCancelTokens[taskId]?.cancel('paused_by_user');
  }

  Future<void> resume(String taskId) => start(taskId);

  /// Retries a failed download from scratch — a failed transfer's `.part`
  /// file is discarded rather than resumed from, since the failure mode
  /// (bad checksum, server error) may mean the partial bytes are corrupt.
  Future<void> retry(String taskId) async {
    final task = await _get(taskId);
    if (task == null) return;
    final partFile = File('${task.localPath}.part');
    if (await partFile.exists()) {
      await partFile.delete();
    }
    task.downloadedBytes = 0;
    task.errorMessage = null;
    task.status = DownloadStatus.queued;
    await _persist(task);
    await start(taskId);
  }

  Future<void> delete(String taskId) async {
    await pause(taskId);
    await DownloadRepository.instance.delete(taskId);
    _progressControllers.remove(taskId)?.close();
  }

  Future<int> storageStatsBytes() =>
      DownloadRepository.instance.totalStorageBytes();

  Future<void> _finalize(DownloadTask task) async {
    final partFile = File('${task.localPath}.part');

    if (task.expectedSha256 != null) {
      final digest = await _sha256Of(partFile);
      if (digest != task.expectedSha256) {
        task.status = DownloadStatus.failed;
        task.errorMessage = 'Checksum mismatch. File may be corrupted.';
        await partFile.delete();
        await _persist(task);
        return;
      }
    }

    await partFile.rename(task.localPath);
    task.status = DownloadStatus.completed;
    await _persist(task);

    // PROJECT_MIGRATION_AUDIT.md Phase 4: this used to write a
    // completion doc to a Firestore `download_logs` collection (a log,
    // not a user-facing notification). Spec §33 explicitly lists
    // "Download completion" as one of the local notification types —
    // this now fires that directly instead, which is both simpler and
    // actually visible to the user, where the Firestore write never was.
    // A dedicated local analytics logger (spec §35, "privacy-first local
    // event logger" for download activity generally) is a separate,
    // broader piece not built here — this only replaces the one
    // completion-log write this file made.
    try {
      await NotificationService.instance.notifyNow(
        title: 'Download complete',
        body: task.title,
        type: 'download_complete',
      );
    } catch (_) {}
  }

  Future<String> _sha256Of(File file) async {
    // AccumulatorSink's exact export path across crypto/convert package
    // versions isn't something I can verify without a live pub.dev/SDK
    // check (this bit CI once already — see PROJECT_MIGRATION_AUDIT.md's
    // CI log entries). A minimal local Sink avoids that guess entirely:
    // dart:core's Sink is always in scope, no extra import needed, and
    // this is exactly the same "start chunked, feed bytes, read result"
    // shape crypto's chunked API expects.
    final digestSink = _SingleValueSink<Digest>();
    final input = sha256.startChunkedConversion(digestSink);
    await for (final chunk in file.openRead()) {
      input.add(chunk);
    }
    input.close();
    return digestSink.value.toString();
  }

  int _resolveTotalBytes(Response<ResponseBody> response, int resumeFrom) {
    final contentRange = response.headers.value('content-range');
    if (contentRange != null) {
      final match = RegExp(r'/(\d+)$').firstMatch(contentRange);
      if (match != null) return int.parse(match.group(1)!);
    }
    final contentLength = response.headers.value('content-length');
    if (contentLength != null) return resumeFrom + int.parse(contentLength);
    return 0; // unknown — progress UI should show indeterminate in this case
  }

  Future<DownloadTask?> _get(String taskId) async {
    final tasks = await DownloadRepository.instance.getAll();
    for (final t in tasks) {
      if (t.id == taskId) return t;
    }
    return null;
  }

  Future<void> _persist(DownloadTask task) async {
    await DownloadRepository.instance.upsert(task);
    _progressControllers[task.id]?.add(task);
  }
}

/// Minimal `Sink<T>` that just keeps the last value written — exactly
/// what `sha256.startChunkedConversion` needs as its output sink. See
/// `_sha256Of`'s doc comment for why this exists instead of importing
/// `AccumulatorSink` from somewhere.
class _SingleValueSink<T> implements Sink<T> {
  T? _value;
  T get value => _value as T;

  @override
  void add(T data) => _value = data;

  @override
  void close() {}
}
