import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/download.dart';
import 'package:mangayomi/modules/manga/download/providers/download_provider.dart';
import 'package:mangayomi/repositories/download_repository.dart';
import 'package:mangayomi/services/download_manager/download_queue_order.dart';
import 'package:mangayomi/utils/extensions/chapter_extensions.dart';

/// Native UIKit download queue backed by the existing Dart queue manager.
class NativeIosDownloadQueue extends ConsumerStatefulWidget {
  const NativeIosDownloadQueue({super.key});

  @override
  ConsumerState<NativeIosDownloadQueue> createState() => _NativeIosDownloadQueueState();
}

class _NativeIosDownloadQueueState extends ConsumerState<NativeIosDownloadQueue> {
  late final Stream<List<Download>> _stream = downloadRepository.watchPending();
  MethodChannel? _channel;
  List<Download> _entries = const [];
  Map<String, Object?> _payload = const {'items': <Object>[]};

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  void _created(int id) {
    _channel = MethodChannel('novayomi/native-downloads/$id');
    _channel?.setMethodCallHandler(_handleNative);
    unawaited(_channel!.invokeMethod<void>('update', _payload));
  }

  Chapter? _chapterFor(Download entry) {
    if (!entry.chapter.isLoaded) entry.chapter.loadSync();
    return entry.chapter.value;
  }

  Future<void> _enqueue(Download entry) async {
    final chapter = _chapterFor(entry);
    if (chapter != null) await downloadRepository.enqueue(chapter);
  }

  Future<void> _handleNative(MethodCall call) async {
    if (!mounted) return;
    try {
      switch (call.method) {
        case 'close':
          if (context.canPop()) context.pop();
        case 'resumeAll':
          for (final entry in _entries) {
            await _enqueue(entry);
          }
          ref.invalidate(processDownloadsProvider());
          ref.read(processDownloadsProvider());
        case 'resume':
          final id = call.arguments as int?;
          if (id == null) return;
          final entry = downloadRepository.getById(id);
          if (entry != null) {
            await _enqueue(entry);
            ref.invalidate(processDownloadsProvider());
            ref.read(processDownloadsProvider());
          }
        case 'cancel':
          final id = call.arguments as int?;
          if (id == null) return;
          final entry = downloadRepository.getById(id);
          if (entry == null) return;
          final chapter = _chapterFor(entry);
          if (chapter == null) {
            await downloadRepository.delete(id);
          } else {
            chapter.cancelDownloads(id);
          }
        case 'cancelSeries':
          final id = call.arguments as int?;
          if (id == null) return;
          final current = downloadRepository.getById(id);
          if (current == null) return;
          final first = _chapterFor(current);
          if (first == null) return;
          if (!first.manga.isLoaded) first.manga.loadSync();
          final manga = first.manga.value;
          if (manga == null) return;
          for (final entry in _entries) {
            final chapter = _chapterFor(entry);
            if (chapter == null || entry.id == null) continue;
            if (!chapter.manga.isLoaded) chapter.manga.loadSync();
            if (chapter.manga.value?.id == manga.id) {
              chapter.cancelDownloads(entry.id!);
            }
          }
      }
    } catch (error, stack) {
      debugPrint('Native downloads: $error');
      debugPrintStack(stackTrace: stack);
      if (mounted) await _channel?.invokeMethod<void>('error', '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Download>>(
      stream: _stream,
      builder: (context, snapshot) {
        final pending = snapshot.data ?? const <Download>[];
        _entries = DownloadQueueOrder.sorted([
          for (final entry in pending)
            if (_chapterFor(entry) != null) entry,
        ]);
        _payload = {
          'items': <Map<String, Object?>>[
            for (final entry in _entries)
              if (entry.id != null)
                {
                  'id': entry.id!,
                  'chapter': _chapterFor(entry)?.name ?? 'Chapter',
                  'book': () {
                    final chapter = _chapterFor(entry);
                    if (chapter == null) return '';
                    if (!chapter.manga.isLoaded) chapter.manga.loadSync();
                    return chapter.manga.value?.name ?? '';
                  }(),
                  'done': entry.succeeded ?? 0,
                  'total': entry.total ?? 0,
                  'failed': entry.failed ?? 0,
                },
          ],
        };
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _channel != null) {
            unawaited(_channel!.invokeMethod<void>('update', _payload));
          }
        });
        return UiKitView(
          viewType: 'novayomi/native-downloads',
          creationParams: _payload,
          creationParamsCodec: const StandardMessageCodec(),
          onPlatformViewCreated: _created,
        );
      },
    );
  }
}
