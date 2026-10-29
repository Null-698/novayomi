import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/settings.dart';
import 'package:mangayomi/modules/library/providers/isar_providers.dart';
import 'package:mangayomi/modules/library/providers/library_filter_provider.dart';
import 'package:mangayomi/modules/library/providers/library_state_provider.dart';
import 'package:mangayomi/modules/library/widgets/library_entry_utils.dart';
import 'package:mangayomi/modules/library/widgets/library_update_runner.dart';
import 'package:mangayomi/modules/library/widgets/continue_shelf.dart';
import 'package:mangayomi/modules/library/providers/library_source_badge_provider.dart';
import 'package:mangayomi/modules/more/categories/providers/isar_providers.dart';
import 'package:mangayomi/modules/more/providers/downloaded_only_state_provider.dart';
import 'package:mangayomi/utils/constant.dart';
import 'package:mangayomi/repositories/manga_repository.dart';
import 'package:mangayomi/repositories/history_repository.dart';
import 'package:mangayomi/modules/more/providers/incognito_mode_state_provider.dart';
import 'package:mangayomi/utils/extensions/chapter_extensions.dart';
import 'package:mangayomi/utils/extensions/manga_extensions.dart';
import 'package:mangayomi/utils/headers.dart';

/// Phase 2.1: UIKit Library surface backed exclusively by existing providers.
/// Staged until native library actions have feature parity with Flutter.
class NativeIosNovelLibrary extends ConsumerStatefulWidget {
  const NativeIosNovelLibrary({super.key});

  @override
  ConsumerState<NativeIosNovelLibrary> createState() => _NativeIosNovelLibraryState();
}

class _NativeIosNovelLibraryState extends ConsumerState<NativeIosNovelLibrary> {
  MethodChannel? _channel;
  List<Manga> _allEntries = const [];
  Settings? _settings;
  Map<String, Object?>? _payload;

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    _channel = null;
    super.dispose();
  }

  void _created(int id) {
    final channel = MethodChannel('novayomi/native-library/$id');
    _channel = channel;
    channel.setMethodCallHandler(_handleAction);
    _sendUpdate();
  }

  Future<void> _handleAction(MethodCall call) async {
    if (!mounted) return;
    switch (call.method) {
      case 'open':
        final id = call.arguments;
        if (id is! int) return;
        Manga? selected;
        for (final book in _allEntries) {
          if (book.id == id) {
            selected = book;
            break;
          }
        }
        if (selected == null) return;
        await onTapEntry(
          isLongPressed: false,
          ref: ref,
          context: context,
          entry: selected,
        );
      case 'resume':
        final id = call.arguments;
        if (id is! int) return;
        final manga = mangaRepository.findById(id);
        if (manga == null || manga.itemType != ItemType.novel) return;
        final history = ref.read(incognitoModeStateProvider)
            ? null : historyRepository.findByMangaId(id);
        if (history != null && !history.chapter.isLoaded) {
          await history.chapter.load();
        }
        final chapters = manga.chapters.toList();
        final target = history?.chapter.value ??
            (chapters.isEmpty ? null : chapters.first);
        if (target != null && mounted) {
          await target.pushToReaderView(context);
        }
      case 'sort':
        final index = call.arguments;
        final settings = _settings;
        if (index is! int || settings == null) return;
        ref.read(sortLibraryMangaStateProvider(
          itemType: ItemType.novel,
          settings: settings,
        ).notifier).set(index);
      case 'layout':
        final list = call.arguments;
        final settings = _settings;
        if (list is! bool || settings == null) return;
        ref.read(libraryDisplayTypeStateProvider(
          itemType: ItemType.novel,
          settings: settings,
        ).notifier).setLibraryDisplayType(
          list ? DisplayType.list : DisplayType.compactGrid,
        );
      case 'gridSize':
        final value = call.arguments;
        if (value is! int || value < 0 || value > 7) return;
        ref.read(libraryGridSizeStateProvider(
          itemType: ItemType.novel,
        ).notifier).set(value, end: true);
      case 'display':
        final index = call.arguments;
        final settings = _settings;
        if (index is! int || settings == null ||
            index < 0 || index >= DisplayType.values.length) return;
        ref.read(libraryDisplayTypeStateProvider(
          itemType: ItemType.novel,
          settings: settings,
        ).notifier).setLibraryDisplayType(DisplayType.values[index]);
      case 'filter':
        final args = call.arguments;
        final settings = _settings;
        if (args is! Map || settings == null) return;
        final key = args['key'] as String?;
        if (key == null) return;
        switch (key) {
          case 'downloaded':
            ref.read(mangaFilterDownloadedStateProvider(
              itemType: ItemType.novel, mangaList: _allEntries, settings: settings,
            ).notifier).update();
          case 'unread':
            ref.read(mangaFilterUnreadStateProvider(
              itemType: ItemType.novel, mangaList: _allEntries, settings: settings,
            ).notifier).update();
          case 'started':
            ref.read(mangaFilterStartedStateProvider(
              itemType: ItemType.novel, mangaList: _allEntries, settings: settings,
            ).notifier).update();
          case 'bookmarked':
            ref.read(mangaFilterBookmarkedStateProvider(
              itemType: ItemType.novel, mangaList: _allEntries, settings: settings,
            ).notifier).update();
          case 'completed':
            ref.read(mangaFilterCompletedStateProvider(
              itemType: ItemType.novel, mangaList: _allEntries, settings: settings,
            ).notifier).update();
          case 'tracking':
            ref.read(mangaFilterTrackingStateProvider(
              itemType: ItemType.novel, mangaList: _allEntries, settings: settings,
            ).notifier).update();
        }
      case 'sources':
        final args = call.arguments;
        final settings = _settings;
        if (args is! List || settings == null) return;
        ref.read(mangaFilterSourceStateProvider(
          mangaList: _allEntries,
          itemType: ItemType.novel,
          settings: settings,
        ).notifier).set(args.whereType<String>().toList());
      case 'displayToggle':
        final args = call.arguments;
        final settings = _settings;
        if (args is! Map || settings == null) return;
        final key = args['key'] as String?;
        final enabled = args['value'] as bool?;
        if (key == null || enabled == null) return;
        switch (key) {
          case 'showCategories':
            ref.read(libraryShowCategoryTabsStateProvider(
              itemType: ItemType.novel, settings: settings,
            ).notifier).set(enabled);
          case 'showCounts':
            ref.read(libraryShowNumbersOfItemsStateProvider(
              itemType: ItemType.novel, settings: settings,
            ).notifier).set(enabled);
          case 'downloadBadges':
            ref.read(libraryDownloadedChaptersStateProvider(
              itemType: ItemType.novel, settings: settings,
            ).notifier).set(enabled);
          case 'showLanguage':
            ref.read(libraryLanguageStateProvider(
              itemType: ItemType.novel, settings: settings,
            ).notifier).set(enabled);
          case 'showSource':
            ref.read(librarySourceBadgeProvider.notifier).set(enabled);
          case 'showLocal':
            ref.read(libraryLocalSourceStateProvider(
              itemType: ItemType.novel, settings: settings,
            ).notifier).set(enabled);
          case 'continueButton':
            ref.read(libraryShowContinueReadingButtonStateProvider(
              itemType: ItemType.novel, settings: settings,
            ).notifier).set(enabled);
          case 'continueShelf':
            ref.read(continueShelfProvider.notifier).set(enabled);
        }
      case 'batch':
        final args = call.arguments;
        if (args is! Map) return;
        final ids = (args['ids'] as List?)?.whereType<int>().toSet() ?? <int>{};
        if (ids.isEmpty) return;
        final kind = args['kind'] as String?;
        switch (kind) {
          case 'markRead':
          case 'markUnread':
            ref.read(mangasSetIsReadStateProvider(
              mangaIds: ids, markAsRead: kind == 'markRead',
            ).notifier).set();
          case 'setCategories':
            final categories = (args['categories'] as List?)
                    ?.whereType<int>().toList() ?? <int>[];
            final timestamp = DateTime.now().millisecondsSinceEpoch;
            final changed = <Manga>[];
            for (final id in ids) {
              final manga = mangaRepository.findById(id);
              if (manga == null || manga.itemType != ItemType.novel) continue;
              manga.categories = categories;
              manga.updatedAt = timestamp;
              changed.add(manga);
            }
            if (changed.isNotEmpty) await mangaRepository.putAll(changed);
          case 'removeFromLibrary':
            for (final id in ids) {
              final manga = mangaRepository.findById(id);
              if (manga != null && manga.itemType == ItemType.novel) {
                await mangaRepository.removeFromLibrary(manga);
              }
            }
        }
        ref.invalidate(getAllMangaStreamProvider(
          categoryId: null, itemType: ItemType.novel,
        ));
      case 'refresh':
        try {
          await updateLibrary(
            ref: ref,
            context: context,
            mangaList: _allEntries,
            itemType: ItemType.novel,
          );
        } finally {
          await _channel?.invokeMethod<void>('refreshComplete');
        }
    }
  }

  void _sendUpdate() {
    final channel = _channel;
    final data = _payload;
    if (channel != null && data != null) {
      unawaited(channel.invokeMethod<void>('update', data));
    }
  }

  List<Map<String, Object?>> _serialize(
    List<Manga> books, {
    required Settings settings,
    required Set<int> downloadedIds,
    required bool showDownloaded,
    required bool showContinue,
  }) {
    final cache = <String, Map<String, String>>{};
    return [
      for (final book in books)
        if (book.id != null)
          <String, Object?>{
            'id': book.id,
            'name': book.name ?? 'Untitled',
            'author': book.author ?? '',
            'source': book.source ?? '',
            'genre': book.genre ?? const <String>[],
            'cover': toImgUrl(book.customCoverFromTracker ?? book.imageUrl ?? ''),
            'categories': book.categories ?? const <int>[],
            'chapterCount': book.chapters.length,
            'unreadCount': book.unreadChaptersCount(settings),
            'downloadedCount': showDownloaded
                ? book.chapters.where((chapter) =>
                    chapter.id != null && downloadedIds.contains(chapter.id)).length
                : 0,
            'showContinue': showContinue && book.chapters.isNotEmpty,
            'isLocal': book.isLocalArchive ?? false,
            if (book.customCoverImage != null)
              'coverBytes': Uint8List.fromList(book.customCoverImage!),
            'headers': (book.isLocalArchive ?? false) ||
                    book.source == null || book.lang == null
                ? const <String, String>{}
                : cache.putIfAbsent(
                    (book.source ?? '') + '|' + (book.lang ?? '') + '|' +
                        (book.sourceId?.toString() ?? ''),
                    () => ref.read(headersProvider(
                      source: book.source!,
                      lang: book.lang!,
                      sourceId: book.sourceId,
                    )),
                  ),
          },
    ];
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(getSettingsStreamProvider).asData?.value;
    final books = ref.watch(getAllMangaStreamProvider(
      categoryId: null,
      itemType: ItemType.novel,
    )).asData?.value;
    final categories = ref.watch(
      getMangaCategorieStreamProvider(itemType: ItemType.novel),
    ).asData?.value;
    if (settings == null || books == null) {
      return const Center(child: CircularProgressIndicator());
    }
    _settings = settings;
    _allEntries = books;
    final sort = ref.watch(sortLibraryMangaStateProvider(
      itemType: ItemType.novel, settings: settings,
    ));
    final display = ref.watch(libraryDisplayTypeStateProvider(
      itemType: ItemType.novel, settings: settings,
    ));
    final gridSize = ref.watch(libraryGridSizeStateProvider(
      itemType: ItemType.novel,
    )) ?? 0;
    final download = ref.watch(mangaFilterDownloadedStateProvider(
      itemType: ItemType.novel, mangaList: books, settings: settings,
    ));
    final unread = ref.watch(mangaFilterUnreadStateProvider(
      itemType: ItemType.novel, mangaList: books, settings: settings,
    ));
    final started = ref.watch(mangaFilterStartedStateProvider(
      itemType: ItemType.novel, mangaList: books, settings: settings,
    ));
    final bookmarked = ref.watch(mangaFilterBookmarkedStateProvider(
      itemType: ItemType.novel, mangaList: books, settings: settings,
    ));
    final completed = ref.watch(mangaFilterCompletedStateProvider(
      itemType: ItemType.novel, mangaList: books, settings: settings,
    ));
    final tracking = ref.watch(mangaFilterTrackingStateProvider(
      itemType: ItemType.novel, mangaList: books, settings: settings,
    ));
    final sources = ref.watch(mangaFilterSourceStateProvider(
      mangaList: books, itemType: ItemType.novel, settings: settings,
    )).$2;
    final downloadedOnly = ref.watch(downloadedOnlyStateProvider);
    final downloadedIds = ref.watch(downloadedChapterIdsProvider).asData?.value
        ?? const <int>{};
    final showCategories = ref.watch(libraryShowCategoryTabsStateProvider(
      itemType: ItemType.novel, settings: settings,
    ));
    final showCounts = ref.watch(libraryShowNumbersOfItemsStateProvider(
      itemType: ItemType.novel, settings: settings,
    ));
    final downloadBadges = ref.watch(libraryDownloadedChaptersStateProvider(
      itemType: ItemType.novel, settings: settings,
    ));
    final languageBadges = ref.watch(libraryLanguageStateProvider(
      itemType: ItemType.novel, settings: settings,
    ));
    final localBadges = ref.watch(libraryLocalSourceStateProvider(
      itemType: ItemType.novel, settings: settings,
    ));
    final sourceBadges = ref.watch(librarySourceBadgeProvider);
    final continueButtons = ref.watch(libraryShowContinueReadingButtonStateProvider(
      itemType: ItemType.novel, settings: settings,
    ));
    final continueShelf = ref.watch(continueShelfProvider);
    final availableSources = ref.watch(mangaFilterSourceStateProvider(
      mangaList: books, itemType: ItemType.novel, settings: settings,
    )).$1;
    final visible = ref.watch(filteredLibraryMangaProvider(
      data: books,
      downloadFilterType: download,
      unreadFilterType: unread,
      startedFilterType: started,
      bookmarkedFilterType: bookmarked,
      completedFilterType: completed,
      trackingFilterType: tracking,
      sortType: sort.index ?? 0,
      downloadedOnly: downloadedOnly,
      searchQuery: '',
      ignoreFiltersOnSearch: false,
      sourceIds: sources,
      settings: settings,
    ));
    _payload = <String, Object?>{
      'title': 'Novels',
      // Keep the full source list separate from visible IDs, so the native
      // search bar can temporarily ignore current filters just as Flutter did.
      'items': _serialize(books,
          settings: settings,
          downloadedIds: downloadedIds,
          showDownloaded: downloadBadges,
          showContinue: continueButtons),
      'visibleIds': [
        for (final book in (sort.reverse == true
            ? (sort.index == 3
                ? sortByUnreadCount(visible,
                    unreadCountOf: (book) => book.unreadChaptersCount(settings),
                    descending: true)
                : visible.reversed.toList())
            : visible))
          if (book.id != null) book.id!,
      ],
      'categories': <Map<String, Object?>>[
        for (final c in (categories ?? []).where((c) => c.hide != true))
          if (c.id != null) <String, Object?>{
            'id': c.id, 'name': c.name ?? 'Collection',
          },
      ],
      'sortIndex': sort.index ?? 0,
      'sortReverse': sort.reverse ?? false,
      'displayIndex': display.index,
      'gridSize': gridSize,
      'isList': display == DisplayType.list,
      'filters': <String, int>{
        'downloaded': download,
        'unread': unread,
        'started': started,
        'bookmarked': bookmarked,
        'completed': completed,
        'tracking': tracking,
      },
      'sources': availableSources,
      'selectedSources': sources,
      'displaySettings': <String, bool>{
        'showCategories': showCategories,
        'showCounts': showCounts,
        'downloadBadges': downloadBadges,
        'showLanguage': languageBadges,
        'showSource': sourceBadges,
        'showLocal': localBadges,
        'continueButton': continueButtons,
        'continueShelf': continueShelf,
      },
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sendUpdate();
    });
    return UiKitView(
      viewType: 'novayomi/native-library',
      creationParams: _payload,
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: _created,
    );
  }
}
