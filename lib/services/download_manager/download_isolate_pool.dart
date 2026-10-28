import 'dart:collection';
import 'dart:isolate';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/page.dart';
import 'package:mangayomi/services/http/m_client.dart';
import 'package:mangayomi/services/http/rhttp/src/model/settings.dart';
import 'package:mangayomi/services/download_manager/download_progress.dart';
import 'package:mangayomi/src/rust/frb_generated.dart';
import 'package:mangayomi/utils/downloaded_page_file.dart';
import 'package:path/path.dart' as path;

final downloadTaskCancellation = <String, bool>{};

/// Shared Isolate pool to optimize performance
/// Instead of creating a new Isolate for each download,
/// we use a limited pool of workers that process tasks in queue.
class DownloadIsolatePool {
  static DownloadIsolatePool? _instance;
  final List<_PoolWorker> _workers = [];
  final Queue<_DownloadTask> _taskQueue = Queue();
  final Set<int> _availableWorkers = {}; // Track available workers by index
  final int poolSize;
  bool _initialized = false;
  Future<void>? _initializing;
  final Map<String, _PoolWorker> _runningTasks = {};
  void Function(SendPort)? _testWorkerEntryPoint;

  @visibleForTesting
  DownloadIsolatePool.forTesting({
    this.poolSize = 1,
    required void Function(SendPort) workerEntryPoint,
  }) : _testWorkerEntryPoint = workerEntryPoint;

  DownloadIsolatePool._({this.poolSize = 3});

  /// Get the singleton instance of the pool
  static DownloadIsolatePool get instance {
    _instance ??= DownloadIsolatePool._();
    return _instance!;
  }

  /// Exercises the real file/HTTP worker without the optional Rust transport.
  /// Tests run on CI before the native app library is built.
  @visibleForTesting
  static void configureForTesting() {
    _instance?.dispose();
    _instance = DownloadIsolatePool.forTesting(
      workerEntryPoint: _dartHttpWorkerEntryPoint,
    );
  }

  /// Configure the pool size (call before initialize)
  static void configure({int poolSize = 3}) {
    if (_instance != null && _instance!._initialized) {
      if (kDebugMode) {
        print('[DownloadPool] Cannot reconfigure after initialization');
      }
      return;
    }
    _instance = DownloadIsolatePool._(poolSize: poolSize);
  }

  /// Initialize the Isolate pool
  Future<void> initialize() =>
      _initializing ??= _initialize().catchError((Object error) {
        for (final worker in _workers) {
          worker.dispose();
        }
        _workers.clear();
        _availableWorkers.clear();
        _initializing = null;
        throw error;
      });

  Future<void> _initialize() async {
    if (_initialized) return;

    if (kDebugMode) {
      print('[DownloadPool] Initializing with $poolSize workers...');
    }

    for (int i = 0; i < poolSize; i++) {
      final worker = await _PoolWorker.create(
        i,
        entryPoint: _testWorkerEntryPoint,
      );
      _workers.add(worker);
      _availableWorkers.add(i); // All workers start as available
    }

    _initialized = true;
    if (kDebugMode) {
      print('[DownloadPool] Pool initialized with $poolSize workers');
    }
  }

  /// Submit a file download task (manga/anime)
  Future<bool> _prepareSubmission(
    String taskId,
    void Function(Exception) onError,
  ) async {
    downloadTaskCancellation[taskId] = false;
    try {
      if (!_initialized) await initialize();
    } catch (_) {
      downloadTaskCancellation.remove(taskId);
      rethrow;
    }
    if (downloadTaskCancellation[taskId] == true) {
      downloadTaskCancellation.remove(taskId);
      onError(Exception('Download cancelled'));
      return false;
    }
    return true;
  }

  Future<void> submitFileDownload({
    required String taskId,
    required List<PageUrl> pageUrls,
    required int concurrentDownloads,
    required ItemType itemType,
    required void Function(DownloadProgress) onProgress,
    required void Function() onComplete,
    required void Function(Exception) onError,
  }) async {
    if (!await _prepareSubmission(taskId, onError)) return;

    final receivePort = ReceivePort();
    final task = _DownloadTask(
      taskId: taskId,
      type: _TaskType.fileDownload,
      params: FileDownloadParams(
        pageUrls: pageUrls,
        concurrentDownloads: concurrentDownloads,
        itemType: itemType,
      ),
      sendPort: receivePort.sendPort,
    );

    // Listen for progress messages
    _listenToTask(receivePort, taskId, onProgress, onComplete, onError);
    _enqueueTask(task);
  }

  void _listenToTask(
    ReceivePort receivePort,
    String taskId,
    void Function(DownloadProgress) onProgress,
    void Function() onComplete,
    void Function(Exception) onError,
  ) {
    receivePort.listen((message) {
      if (message is DownloadProgress) {
        onProgress(message);
      } else if (message is DownloadComplete || message is Exception) {
        downloadTaskCancellation.remove(taskId);
        receivePort.close();
        if (message is DownloadComplete) onComplete();
        if (message is Exception) onError(message);
      }
    });
  }

  /// Cancel a download task
  void cancelTask(String taskId) {
    if (downloadTaskCancellation.containsKey(taskId)) {
      downloadTaskCancellation[taskId] = true;
    }
    final queued = _taskQueue.where((task) => task.taskId == taskId).toList();
    _taskQueue.removeWhere((task) => task.taskId == taskId);
    for (final task in queued) {
      task.sendPort.send(Exception('Download cancelled'));
    }
    _runningTasks[taskId]?.cancelCurrentTask();
  }

  /// Add a task to the queue and try to process it
  void _enqueueTask(_DownloadTask task) {
    _taskQueue.add(task);
    _processQueue();
  }

  /// Process the task queue
  void _processQueue() {
    while (_taskQueue.isNotEmpty && _availableWorkers.isNotEmpty) {
      final task = _taskQueue.removeFirst();
      final workerIndex = _availableWorkers.first;
      _availableWorkers.remove(workerIndex);
      final worker = _workers[workerIndex];

      if (kDebugMode) {
        print(
          '[DownloadPool] Worker $workerIndex starting task ${task.taskId}',
        );
      }

      _runningTasks[task.taskId] = worker;
      worker.executeTask(task).then((_) async {
        _runningTasks.remove(task.taskId);
        if (worker.terminated) {
          _workers[workerIndex] = await _PoolWorker.create(
            workerIndex,
            entryPoint: _testWorkerEntryPoint,
          );
        }
        _availableWorkers.add(workerIndex); // Worker is free again
        if (kDebugMode) {
          print(
            '[DownloadPool] Worker $workerIndex finished task ${task.taskId}, available workers: ${_availableWorkers.length}',
          );
        }
        _processQueue(); // Process the next task
      });
    }
  }

  /// Number of pending tasks
  int get pendingTasks => _taskQueue.length;

  /// Number of active workers
  int get activeWorkers => poolSize - _availableWorkers.length;

  /// Close the pool
  void dispose() {
    for (final worker in _workers) {
      worker.dispose();
    }
    _workers.clear();
    _taskQueue.clear();
    _availableWorkers.clear();
    downloadTaskCancellation.clear();
    _initialized = false;
    _initializing = null;
    _runningTasks.clear();
  }
}

/// Supported task types
enum _TaskType { fileDownload }

/// Download task
class _DownloadTask {
  final String taskId;
  final _TaskType type;
  final dynamic params;
  final SendPort sendPort;

  _DownloadTask({
    required this.taskId,
    required this.type,
    required this.params,
    required this.sendPort,
  });
}

/// Parameters for file download
class FileDownloadParams {
  final List<PageUrl> pageUrls;
  final int concurrentDownloads;
  final ItemType itemType;

  FileDownloadParams({
    required this.pageUrls,
    required this.concurrentDownloads,
    required this.itemType,
  });
}

/// Pool worker that executes tasks in a persistent Isolate
class _PoolWorker {
  final int id;
  late Isolate _isolate;
  late SendPort _sendPort;
  late ReceivePort _receivePort;
  final Completer<void> _ready = Completer();
  void Function(Exception)? _cancelCurrent;
  bool terminated = false;

  void cancelCurrentTask() =>
      _cancelCurrent?.call(Exception('Download cancelled'));

  _PoolWorker._(this.id);

  static Future<_PoolWorker> create(
    int id, {
    void Function(SendPort)? entryPoint,
  }) async {
    final worker = _PoolWorker._(id);
    await worker._spawn(entryPoint);
    return worker;
  }

  Future<void> _spawn(void Function(SendPort)? entryPoint) async {
    _receivePort = ReceivePort();

    _isolate = await Isolate.spawn(
      entryPoint ?? _workerEntryPoint,
      _receivePort.sendPort,
      onError: _receivePort.sendPort,
      onExit: _receivePort.sendPort,
    );

    // Wait for the worker to be ready and get its SendPort
    final completer = Completer<SendPort>();
    _receivePort.listen((message) {
      if (message is SendPort) {
        if (!completer.isCompleted) completer.complete(message);
      } else {
        final error = DownloadPoolException(
          'Download worker exited or failed to initialize',
          message,
        );
        if (!completer.isCompleted) {
          completer.completeError(error);
        } else {
          _cancelCurrent?.call(error);
        }
      }
    });

    try {
      _sendPort = await completer.future.timeout(const Duration(seconds: 30));
    } catch (_) {
      _isolate.kill(priority: Isolate.immediate);
      _receivePort.close();
      rethrow;
    }
    _ready.complete();
  }

  /// Execute a task in this worker
  Future<void> executeTask(_DownloadTask task) async {
    await _ready.future;

    final completer = Completer<void>();

    // Create a port to receive messages from this worker
    final taskPort = ReceivePort();
    _cancelCurrent = (error) {
      // Cancellation must stop disk writes and settle the waiting downloader,
      // otherwise its per-source gate remains held forever.
      _cancelCurrent = null;
      terminated = true;
      _isolate.kill(priority: Isolate.immediate);
      _receivePort.close();
      taskPort.close();
      task.sendPort.send(error);
      if (!completer.isCompleted) completer.complete();
    };

    taskPort.listen((message) {
      // Forward the message to the original task port
      task.sendPort.send(message);

      if (message is DownloadComplete || message is Exception) {
        _cancelCurrent = null;
        taskPort.close();
        completer.complete();
      }
    });

    // Send the task to the worker
    _sendPort.send(
      _WorkerTask(
        taskId: task.taskId,
        type: task.type,
        params: task.params,
        replyPort: taskPort.sendPort,
      ),
    );

    return completer.future;
  }

  void dispose() {
    _isolate.kill();
    _receivePort.close();
  }
}

/// Task sent to the worker
class _WorkerTask {
  final String taskId;
  final _TaskType type;
  final dynamic params;
  final SendPort replyPort;

  _WorkerTask({
    required this.taskId,
    required this.type,
    required this.params,
    required this.replyPort,
  });
}

/// Isolate worker entry point
void _workerEntryPoint(SendPort mainPort) async {
  // Initialize dependencies in the Isolate
  await RustLib.init();

  final httpClient = MClient.httpClient(
    settings: const ClientSettings(
      throwOnStatusCode: false,
      tlsSettings: TlsSettings(verifyCertificates: false),
    ),
  );

  await _runWorker(mainPort, httpClient);
}

void _dartHttpWorkerEntryPoint(SendPort mainPort) async {
  await _runWorker(mainPort, Client());
}

Future<void> _runWorker(SendPort mainPort, Client httpClient) async {
  // Create the receive port for this worker
  final receivePort = ReceivePort();

  // Send the SendPort to the main isolate
  mainPort.send(receivePort.sendPort);

  if (kDebugMode) {
    print('[Download worker] Ready');
  }

  // Listen for tasks
  await for (final message in receivePort) {
    if (message is _WorkerTask) {
      try {
        if (message.type == _TaskType.fileDownload) {
          await _processFileDownload(
            message.params as FileDownloadParams,
            message.replyPort,
            httpClient,
          );
        }
      } catch (e) {
        message.replyPort.send(DownloadPoolException('Task failed', e));
      }
    }
  }
}

/// Process a file download
Future<void> _processFileDownload(
  FileDownloadParams params,
  SendPort replyPort,
  Client client,
) async {
  int completed = 0;
  final total = params.pageUrls.length;
  final queue = Queue<PageUrl>.from(params.pageUrls);
  final List<Future<void>> activeTasks = [];

  try {
    while (queue.isNotEmpty || activeTasks.isNotEmpty) {
      while (queue.isNotEmpty &&
          activeTasks.length < params.concurrentDownloads) {
        final pageUrl = queue.removeFirst();
        final task = _downloadFile(pageUrl, client)
            .then((_) {
              completed++;
              replyPort.send(
                DownloadProgress(
                  pageUrl: pageUrl,
                  completed,
                  total,
                  params.itemType,
                ),
              );
            })
            .catchError((error) {
              replyPort.send(
                DownloadPoolException(
                  'Error downloading ${pageUrl.fileName}',
                  error,
                ),
              );
              throw error;
            });

        activeTasks.add(task);
      }

      if (activeTasks.isNotEmpty) {
        await Future.wait(activeTasks.toList(), eagerError: true);
        activeTasks.clear();
      }
    }

    replyPort.send(DownloadComplete());
  } catch (e) {
    replyPort.send(DownloadPoolException('Download failed', e));
  }
}

/// Download an individual image page.
Future<void> _downloadFile(PageUrl pageUrl, Client client) async {
  try {
    final response = await _withRetry(
      () => client
          .get(Uri.parse(pageUrl.url), headers: pageUrl.headers)
          .timeout(const Duration(seconds: 30)),
      3,
    );
    if (response.statusCode != 200) {
      throw DownloadPoolException(
        'Failed to download file: ${pageUrl.fileName!}',
      );
    }
    final realExt = detectImageExtension(response.bodyBytes);
    final targetFile = File(path.setExtension(pageUrl.fileName!, realExt));
    await targetFile.writeAsBytes(response.bodyBytes);
  } catch (e) {
    throw DownloadPoolException(
      'Failed to process file: ${pageUrl.fileName!}',
      e,
    );
  }
}

/// Helper for retry
Future<T> _withRetry<T>(Future<T> Function() operation, int maxRetries) async {
  int attempts = 0;
  while (true) {
    try {
      attempts++;
      return await operation();
    } catch (e) {
      if (attempts >= maxRetries) {
        throw DownloadPoolException(
          'Operation failed after $maxRetries attempts',
          e,
        );
      }
    }
  }
}

/// Pool exception
class DownloadPoolException implements Exception {
  final String message;
  final dynamic originalError;

  DownloadPoolException(this.message, [this.originalError]);

  @override
  String toString() =>
      'DownloadPoolException: $message${originalError != null ? ' ($originalError)' : ''}';
}
