import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/modules/manga/detail/manga_detail_main.dart';
import 'package:mangayomi/modules/manga/detail/providers/isar_providers.dart';
import 'package:mangayomi/modules/manga/detail/providers/update_manga_detail_providers.dart';
import 'package:mangayomi/modules/manga/detail/widgets/read_action.dart';
import 'package:mangayomi/modules/manga/download/providers/download_provider.dart';
import 'package:mangayomi/modules/library/providers/library_filter_provider.dart';
import 'package:mangayomi/modules/more/providers/incognito_mode_state_provider.dart';
import 'package:mangayomi/repositories/chapter_repository.dart';
import 'package:mangayomi/repositories/download_repository.dart';
import 'package:mangayomi/repositories/manga_repository.dart';
import 'package:mangayomi/utils/constant.dart';
import 'package:mangayomi/utils/headers.dart';
import 'package:mangayomi/utils/extensions/chapter_extensions.dart';
import 'package:mangayomi/utils/extensions/manga_extensions.dart';

/// Phase 2.2: native iOS UIKit novel details with the original Dart backend.
class NativeIosNovelDetail extends ConsumerStatefulWidget {
  final int mangaId;
  const NativeIosNovelDetail({super.key, required this.mangaId});

  @override
  ConsumerState<NativeIosNovelDetail> createState() => _NativeIosNovelDetailState();
}

class _NativeIosNovelDetailState extends ConsumerState<NativeIosNovelDetail> {
  // UI snapshots only, not a second data store: all operations still read
  // from the original repositories and the live Isar stream.
  static final Map<int, Map<String, Object?>> _lastPayloadByManga = {};
  MethodChannel? _channel;
  Manga? _manga;
  Map<String, Object?> _payload = {
    'title': 'Loading novel…',
    'chapters': <Object>[],
  };

  @override
  void initState() {
    super.initState();
    // Restore the last known UIKit state before the asynchronous Isar stream
    // emits. Returning from the reader must not display "Loading novel…".
    _payload = _lastPayloadByManga[widget.mangaId] ??
        {'title': 'Loading novel…', 'chapters': <Object>[]};
    final local = mangaRepository.findById(widget.mangaId);
    if (local != null && !local.chapters.isLoaded) local.chapters.loadSync();
    // Only query the remote source when this work has not been populated.
    if (local == null || local.chapters.isEmpty) {
      unawaited(_refresh(initial: true));
    }
  }

  Future<void> _refresh({required bool initial}) async {
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    try {
      await ref.read(updateMangaDetailProvider(
        mangaId: widget.mangaId,
        isInit: initial,
      ).future);
    } catch (error) {
      if (mounted) await _channel?.invokeMethod<void>('error', '$error');
    } finally {
      if (mounted) await _channel?.invokeMethod<void>('refreshComplete');
    }
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  void _created(int id) {
    final channel = MethodChannel('novayomi/native-novel-detail/$id');
    _channel = channel;
    channel.setMethodCallHandler(_handleNative);
    unawaited(channel.invokeMethod<void>('update', _payload));
  }

  Future<void> _handleNative(MethodCall call) async {
    if (!mounted) return;
    try {
      final manga = _manga;
      switch (call.method) {
        case 'close':
          if (context.canPop()) context.pop();
        case 'refresh':
          await _refresh(initial: false);
        case 'read':
          final id = call.arguments as int?;
          if (id == null) return;
          final chapter = chapterRepository.findByIdSync(id);
          if (chapter != null && chapter.mangaId == widget.mangaId && mounted) {
            await chapter.pushToReaderView(context);
          }
        case 'resume':
          if (manga == null) return;
          final resume = resumeChapterFor(
            manga, incognito: ref.read(incognitoModeStateProvider),
          ) ?? firstUnreadChapterFor(manga);
          if (resume != null && mounted) {
            await resume.pushToReaderView(context);
          }
        case 'toggleRead':
        case 'toggleBookmark':
          final id = call.arguments as int?;
          if (id == null) return;
          final chapter = chapterRepository.findByIdSync(id);
          if (chapter == null || chapter.mangaId != widget.mangaId) return;
          if (call.method == 'toggleRead') {
            chapter.isRead = !(chapter.isRead ?? false);
            if (!(chapter.isRead ?? false)) chapter.lastPageRead = '1';
          } else {
            chapter.isBookmarked = !(chapter.isBookmarked ?? false);
          }
          await chapterRepository.save(chapter);
        case 'download':
          final id = call.arguments as int?;
          if (id == null) return;
          final chapter = chapterRepository.findByIdSync(id);
          if (chapter == null || chapter.mangaId != widget.mangaId ||
              downloadRepository.getByChapterId(id)?.isDownload == true) return;
          await downloadRepository.enqueue(chapter);
          ref.invalidate(processDownloadsProvider());
          ref.read(processDownloadsProvider());
        case 'downloadUnread':
          if (manga == null) return;
          for (final chapter in manga.getChapterListForReading()) {
            if (chapter.id == null || (chapter.isRead ?? false) ||
                downloadRepository.getByChapterId(chapter.id)?.isDownload == true) {
              continue;
            }
            await downloadRepository.enqueue(chapter);
          }
          ref.invalidate(processDownloadsProvider());
          ref.read(processDownloadsProvider());
        case 'favorite':
          if (manga == null) return;
          if (manga.favorite == true) {
            manga.favorite = false;
          } else {
            final duplicates = await mangaRepository.findFavoritesByItemTypeAndName(
              manga.itemType, manga.name,
            );
            if (duplicates.any((other) => other.id != manga.id)) {
              throw StateError('This novel is already in your Library from another source.');
            }
            manga.favorite = true;
            manga.dateAdded ??= DateTime.now().millisecondsSinceEpoch;
          }
          await mangaRepository.save(manga);
      }
    } catch (error, stack) {
      debugPrint('Native novel details: $error');
      debugPrintStack(stackTrace: stack);
      if (mounted) {
        await _channel?.invokeMethod<void>('error', error.toString());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // The repository has the cached novel synchronously. Riverpod streams may
    // still be loading after a reader pop; never replace visible details with
    // a blank loading screen during that interval.
    final streamed = ref.watch(getMangaDetailStreamProvider(
      mangaId: widget.mangaId,
    )).asData?.value;
    final manga = streamed ?? mangaRepository.findById(widget.mangaId);
    if (manga != null && !manga.chapters.isLoaded) manga.chapters.loadSync();
    if (manga != null && manga.itemType != ItemType.novel) {
      return MangaReaderDetail(mangaId: widget.mangaId);
    }
    if (manga != null) {
      _manga = manga;
      ref.watch(getChaptersStreamProvider(mangaId: widget.mangaId));
      final chapters = manga.getSortedFilteredChapters();
      final downloaded = ref.watch(downloadedChapterIdsProvider).asData?.value
          ?? const <int>{};
      final resume = resumeChapterFor(
        manga, incognito: ref.watch(incognitoModeStateProvider),
      ) ?? firstUnreadChapterFor(manga);
      _payload = {
        'title': manga.name ?? 'Untitled',
        'author': manga.author ?? '',
        'status': manga.status.name,
        'description': manga.description ?? '',
        'source': manga.source ?? '',
        'genres': manga.genre ?? const <String>[],
        'favorite': manga.favorite ?? false,
        'chapterCount': chapters.length,
        'readChapterId': resume?.id,
        'cover': toImgUrl(
          manga.customCoverFromTracker ?? manga.imageUrl ?? '',
        ),
        if (manga.customCoverImage != null)
          'coverBytes': Uint8List.fromList(manga.customCoverImage!),
        'headers': manga.isLocalArchive == true || manga.source == null ||
                manga.lang == null
            ? const <String, String>{}
            : ref.read(headersProvider(
                source: manga.source!,
                lang: manga.lang!,
                sourceId: manga.sourceId,
              )),
        'chapters': [
          for (final chapter in chapters)
            if (chapter.id != null)
              {
                'id': chapter.id,
                'name': chapter.name ?? 'Chapter',
                'date': chapter.dateUpload ?? '',
                'scanlator': chapter.scanlator ?? '',
                'read': chapter.isRead ?? false,
                'bookmark': chapter.isBookmarked ?? false,
                'downloaded': downloaded.contains(chapter.id),
              },
        ],
      };
      // Bound the UI-only snapshot cache; long chapter lists can be large.
      _lastPayloadByManga.remove(widget.mangaId);
      _lastPayloadByManga[widget.mangaId] = _payload;
      while (_lastPayloadByManga.length > 3) {
        _lastPayloadByManga.remove(_lastPayloadByManga.keys.first);
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _channel != null) {
        unawaited(_channel!.invokeMethod<void>('update', _payload));
      }
    });
    return UiKitView(
      viewType: 'novayomi/native-novel-detail',
      creationParams: _payload,
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: _created,
    );
  }
}
