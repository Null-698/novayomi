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
import 'package:mangayomi/modules/more/categories/providers/isar_providers.dart';
import 'package:mangayomi/modules/more/providers/downloaded_only_state_provider.dart';
import 'package:mangayomi/utils/constant.dart';
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

  List<Map<String, Object?>> _serialize(List<Manga> books) {
    final cache = <String, Map<String, String>>{};
    return [
      for (final book in books)
        if (book.id != null)
          <String, Object?>{
            'id': book.id,
            'name': book.name ?? 'Untitled',
            'author': book.author ?? '',
            'cover': toImgUrl(book.customCoverFromTracker ?? book.imageUrl ?? ''),
            'categories': book.categories ?? const <int>[],
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
      'items': _serialize(sort.reverse == true
          ? visible.reversed.toList() : visible),
      'categories': <Map<String, Object?>>[
        for (final c in (categories ?? []).where((c) => c.hide != true))
          if (c.id != null) <String, Object?>{
            'id': c.id, 'name': c.name ?? 'Collection',
          },
      ],
      'sortIndex': sort.index ?? 0,
      'isList': display == DisplayType.list,
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
