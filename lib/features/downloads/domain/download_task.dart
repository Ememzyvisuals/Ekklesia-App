/// A single offline-download entry (a sermon video's audio track, a
/// radio recording, etc.) — the "Download Engine" requirement: queue,
/// pause, resume, retry, checksum, delete, storage stats, progress.
enum DownloadStatus { queued, downloading, paused, completed, failed }

class DownloadTask {
  DownloadTask({
    required this.id,
    required this.title,
    required this.sourceUrl,
    required this.localPath,
    this.status = DownloadStatus.queued,
    this.totalBytes = 0,
    this.downloadedBytes = 0,
    this.expectedSha256,
    this.errorMessage,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  final String title;
  final String sourceUrl;

  /// Absolute path on device storage where the completed file lives (or
  /// will live once completed). The in-progress `.part` file used for
  /// resumable downloads lives alongside it at `$localPath.part`.
  final String localPath;

  DownloadStatus status;
  int totalBytes;
  int downloadedBytes;

  /// Optional — when provided by the source, verified against the
  /// downloaded file's actual sha256 before marking `completed`.
  final String? expectedSha256;

  String? errorMessage;
  final DateTime createdAt;

  double get progress => totalBytes == 0 ? 0 : downloadedBytes / totalBytes;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'source_url': sourceUrl,
        'local_path': localPath,
        'status': status.name,
        'total_bytes': totalBytes,
        'downloaded_bytes': downloadedBytes,
        'expected_sha256': expectedSha256,
        'error_message': errorMessage,
        'created_at': createdAt.toIso8601String(),
      };

  factory DownloadTask.fromJson(Map<String, dynamic> json) => DownloadTask(
        id: json['id'] as String,
        title: json['title'] as String,
        sourceUrl: json['source_url'] as String,
        localPath: json['local_path'] as String,
        status: DownloadStatus.values.firstWhere(
          (s) => s.name == json['status'],
          orElse: () => DownloadStatus.queued,
        ),
        totalBytes: json['total_bytes'] as int? ?? 0,
        downloadedBytes: json['downloaded_bytes'] as int? ?? 0,
        expectedSha256: json['expected_sha256'] as String?,
        errorMessage: json['error_message'] as String?,
        createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ??
            DateTime.now(),
      );
}
