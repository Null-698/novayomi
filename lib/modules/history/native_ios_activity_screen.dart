import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/modules/history/providers/isar_providers.dart';
import 'package:mangayomi/modules/library/widgets/library_update_runner.dart';
import 'package:mangayomi/modules/manga/download/providers/download_provider.dart';
import 'package:mangayomi/repositories/chapter_repository.dart';
import 'package:mangayomi/repositories/download_repository.dart';
import 'package:mangayomi/repositories/history_repository.dart';
import 'package:mangayomi/repositories/manga_repository.dart';
import 'package:mangayomi/repositories/update_repository.dart';
import 'package:mangayomi/utils/extensions/chapter_extensions.dart';

/// Updates and History share one fully native UIKit presentation. The original
/// Isar streams and sync-aware repositories remain authoritative.
class NativeIosActivityScreen extends ConsumerStatefulWidget {
  final int initialTab;
  const NativeIosActivityScreen({super.key, required this.initialTab});

  @override
  ConsumerState<NativeIosActivityScreen> createState() => _NativeIosActivityScreenState();
}

class _NativeIosActivityScreenState extends ConsumerState<NativeIosActivityScreen> {
  MethodChannel? _channel;
  Map<String, Object?> _payload = const {'updates': <Object>[], 'history': <Object>[]};

  void _created(int id) {
    final channel = MethodChannel('novayomi/native-activity/$id');
    _channel = channel;
    channel.setMethodCallHandler(_handleNative);
    unawaited(channel.invokeMethod<void>('update', _payload));
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  Future<void> _handleNative(MethodCall call) async {
    if (!mounted) return;
    try {
      switch (call.method) {
        case 'read':
          final id = call.arguments as int?;
          if (id == null) return;
          final chapter = chapterRepository.findByIdSync(id);
          if (chapter != null && mounted) {
            await chapter.pushToReaderView(context);
          }
        case 'download':
          final id = call.arguments as int?;
          if (id == null) return;
          final chapter = chapterRepository.findByIdSync(id);
          if (chapter == null || chapter.mangaId == null ||
              mangaRepository.findById(chapter.mangaId!)?.itemType != ItemType.novel ||
              downloadRepository.getByChapterId(id)?.isDownload == true) return;
          await downloadRepository.enqueue(chapter);
          ref.invalidate(processDownloadsProvider());
          ref.read(processDownloadsProvider());
        case 'removeHistory':
          final id = call.arguments as int?;
          if (id != null) await historyRepository.delete(id);
        case 'removeUpdate':
          final id = call.arguments as int?;
          if (id != null) await updateRepository.deleteAll([id]);
        case 'clear':
          final mode = call.arguments as String?;
          if (mode == 'history') {
            final ids = await historyRepository.getIdsByItemType(ItemType.novel);
            if (ids.isNotEmpty) await historyRepository.deleteAll(ids);
          } else if (mode == 'updates') {
            final ids = await updateRepository.getIdsByItemType(ItemType.novel);
            if (ids.isNotEmpty) await updateRepository.deleteAll(ids);
          }
        case 'refresh':
          final books = await mangaRepository.getFavoritesNonLocalArchiveByItemType(
            ItemType.novel,
          );
          if (mounted) {
            await updateLibrary(
              ref: ref, context: context, mangaList: books,
              itemType: ItemType.novel, wholeLibrary: true,
            );
          }
      }
    } catch (e, stack) {
      debugPrint('Native Activity error: $e');
      debugPrintStack(stackTrace: stack);
      if (mounted) await _channel?.invokeMethod<void>('error', '$e');
    } finally {
      if (mounted && call.method == 'refresh') {
        await _channel?.invokeMethod<void>('refreshComplete');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final historyRows = ref.watch(getAllHistoryStreamProvider(
      itemType: ItemType.novel,
    )).asData?.value ?? const [];
    final updatesRows = ref.watch(getAllUpdateStreamProvider(
      itemType: ItemType.novel,
    )).asData?.value ?? const [];

    // Reuse Flutter's batched history resolver to avoid a database load for
    // every visible UIKit cell.
    final chapterIds = historyRows.map((h) => h.chapterId)
        .whereType<int>().toSet().toList();
    final chapterById = <int, Chapter>{
      for (final c in chapterRepository.getAllByIds(chapterIds))
        if (c != null && c.id != null) c.id!: c,
    };
    final chapterByUpdateId = <int, Chapter>{};
    for (final update in updatesRows) {
      if (!update.chapter.isLoaded) update.chapter.loadSync();
      final chapter = update.chapter.value;
      if (chapter != null && update.id != null) {
        chapterByUpdateId[update.id!] = chapter;
      }
    }
    final mangaIds = <int>{
      for (final c in chapterById.values) if (c.mangaId != null) c.mangaId!,
      for (final c in chapterByUpdateId.values) if (c.mangaId != null) c.mangaId!,
    };
    final mangaById = <int, Manga>{
      for (final manga in mangaRepository.getAllByIds(mangaIds.toList()))
        if (manga != null && manga.id != null) manga.id!: manga,
    };
    _payload = {
      'tab': widget.initialTab,
      'history': <Map<String, Object?>>[
        for (final history in historyRows)
          if (chapterById[history.chapterId] case final Chapter chapter)
            if (mangaById[chapter.mangaId] case final Manga manga)
              if (history.id != null && chapter.id != null)
                {
                  'id': history.id!,
                  'chapterId': chapter.id!,
                  'chapter': chapter.name ?? 'Chapter',
                  'book': manga.name ?? 'Novel',
                  'date': history.date ?? '',
                },
      ],
      'updates': <Map<String, Object?>>[
        for (final update in updatesRows)
          if (chapterByUpdateId[update.id] case final Chapter chapter)
            if (mangaById[chapter.mangaId] case final Manga manga)
              if (update.id != null && chapter.id != null)
                {
                  'id': update.id!,
                  'chapterId': chapter.id!,
                  'chapter': chapter.name ?? 'Chapter',
                  'book': manga.name ?? 'Novel',
                  'date': update.date ?? '',
                },
      ],
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _channel != null) {
        unawaited(_channel!.invokeMethod<void>('update', _payload));
      }
    });
    return UiKitView(
      viewType: 'novayomi/native-activity',
      creationParams: _payload,
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: _created,
    );
  }
}
