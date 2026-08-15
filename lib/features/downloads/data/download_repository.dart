import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/download_task.dart';

/// Persists download task metadata (not the files themselves — those live
/// on disk at each task's [DownloadTask.localPath]) via SharedPreferences
/// as a JSON list. A dedicated Drift table would scale better for a very
/// large download library — not done here since this repository was
/// already fully local before the Phase 1 Drift migration and moving it
/// wasn't part of that pass's scope (see PROJECT_MIGRATION_AUDIT.md).
class DownloadRepository {
  DownloadRepository._internal();
  static final DownloadRepository instance = DownloadRepository._internal();

  static const _storageKey = 'download_tasks_v1';

  Future<List<DownloadTask>> getAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => DownloadTask.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveAll(List<DownloadTask> tasks) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _storageKey, jsonEncode(tasks.map((t) => t.toJson()).toList()));
  }

  Future<void> upsert(DownloadTask task) async {
    final tasks = await getAll();
    final index = tasks.indexWhere((t) => t.id == task.id);
    if (index >= 0) {
      tasks[index] = task;
    } else {
      tasks.add(task);
    }
    await saveAll(tasks);
  }

  /// Deletes both the task record and its file(s) on disk (completed file
  /// plus any leftover `.part`).
  Future<void> delete(String taskId) async {
    final tasks = await getAll();
    DownloadTask? task;
    for (final t in tasks) {
      if (t.id == taskId) {
        task = t;
        break;
      }
    }
    tasks.removeWhere((t) => t.id == taskId);
    await saveAll(tasks);

    if (task == null) return;
    for (final path in [task.localPath, '${task.localPath}.part']) {
      final file = File(path);
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {
          // Best-effort — orphan cleanup handled separately by CleanupWorker.
        }
      }
    }
  }

  /// Total bytes on disk across all completed downloads — backs the
  /// "storage statistics" requirement.
  Future<int> totalStorageBytes() async {
    final tasks = await getAll();
    var total = 0;
    for (final task in tasks) {
      if (task.status != DownloadStatus.completed) continue;
      final file = File(task.localPath);
      if (await file.exists()) {
        total += await file.length();
      }
    }
    return total;
  }
}
