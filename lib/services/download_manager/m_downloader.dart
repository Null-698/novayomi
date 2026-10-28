import 'dart:async';

import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/page.dart';
import 'package:mangayomi/services/download_manager/download_isolate_pool.dart';
import 'package:mangayomi/services/download_manager/download_progress.dart';

/// Tracks active chapter downloads for cancellation.
final isolateChapsSendPorts = <String?, dynamic>{};

class MDownloader {
  final List<PageUrl> pageUrls;
  final int concurrentDownloads;
  final Chapter chapter;

  MDownloader({
    required this.chapter,
    required this.pageUrls,
    this.concurrentDownloads = 1,
  });

  static Future<void> initializeIsolatePool({int poolSize = 6}) async {
    DownloadIsolatePool.configure(poolSize: poolSize);
    await DownloadIsolatePool.instance.initialize();
  }

  void close() {
    DownloadIsolatePool.instance.cancelTask('${chapter.id}');
    isolateChapsSendPorts.remove('${chapter.id}');
  }

  Future<void> download(void Function(DownloadProgress) onProgress) async {
    try {
      await _downloadFilesWithProgress(pageUrls, onProgress);
    } catch (e) {
      throw MDownloaderException('Download failed', e);
    } finally {
      close();
    }
  }

  Future<void> _downloadFilesWithProgress(
    List<PageUrl> pageUrls,
    void Function(DownloadProgress) onProgress,
  ) async {
    final completer = Completer<void>();
    final taskId = '${chapter.id}';
    isolateChapsSendPorts[taskId] = true;
    await DownloadIsolatePool.instance.submitFileDownload(
      taskId: taskId,
      pageUrls: pageUrls,
      concurrentDownloads: concurrentDownloads,
      itemType: chapter.manga.value!.itemType,
      onProgress: onProgress,
      onComplete: () {
        onProgress(
          DownloadProgress(
            1,
            1,
            chapter.manga.value!.itemType,
            isCompleted: true,
          ),
        );
        if (!completer.isCompleted) completer.complete();
      },
      onError: (error) {
        if (!completer.isCompleted) completer.completeError(error);
      },
    );
    return completer.future;
  }
}

class MDownloaderException implements Exception {
  final String message;
  final dynamic originalError;

  MDownloaderException(this.message, [this.originalError]);

  @override
  String toString() =>
      'MDownloaderException: $message${originalError != null ? ' ($originalError)' : ''}';
}
