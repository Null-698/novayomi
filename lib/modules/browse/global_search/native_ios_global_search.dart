import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangayomi/eval/model/m_manga.dart';
import 'package:mangayomi/eval/model/m_pages.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/modules/manga/widgets/manga_image_card_widget.dart';
import 'package:mangayomi/modules/more/settings/browse/providers/browse_state_provider.dart';
import 'package:mangayomi/repositories/source_repository.dart';
import 'package:mangayomi/services/get_popular.dart';
import 'package:mangayomi/services/search.dart';

/// Native global-search presentation. The original isolate-backed per-source
/// search engine remains authoritative; requests run three at a time.
class NativeIosGlobalSearch extends ConsumerStatefulWidget {
  const NativeIosGlobalSearch({super.key, this.search, required this.itemType});
  final String? search;
  final ItemType itemType;
  @override
  ConsumerState<NativeIosGlobalSearch> createState() => _NativeIosGlobalSearchState();
}

class _NativeIosGlobalSearchState extends ConsumerState<NativeIosGlobalSearch> {
  MethodChannel? _channel;
  late String query = widget.search ?? '';
  final List<(Source, MManga)> _results = [];
  final Map<int, int> _lastPages = {};
  final Set<int> _hasMore = {};
  bool _loading = false;
  int _generation = 0;
  Map<String, Object?> _snapshot = const {};

  List<Source> get _sources {
    final pinned = ref.read(onlyIncludePinnedSourceStateProvider);
    final nsfw = ref.read(showNSFWStateProvider);
    final selected = pinned
        ? sourceRepository.getPinnedByItemType(widget.itemType)
        : sourceRepository.getAddedByItemType(widget.itemType);
    return [
      for (final source in selected)
        if (source.id != null &&
            (source.isActive ?? true) &&
            (nsfw || !(source.isNsfw ?? false)))
          source,
    ];
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refresh());
    });
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    _generation++;
    super.dispose();
  }

  void _created(int id) {
    _channel = MethodChannel('novayomi/native-source-results/$id');
    _channel!.setMethodCallHandler(_handle);
    unawaited(_channel!.invokeMethod<void>('update', _snapshot));
  }

  Future<void> _handle(MethodCall call) async {
    if (!mounted) return;
    switch (call.method) {
      case 'close':
        if (context.canPop()) context.pop();
      case 'search':
        query = (call.arguments as String? ?? '').trim();
        await _refresh();
      case 'refresh':
        await _refresh();
      case 'loadMore':
        await _fetch(next: true);
      case 'open':
        final index = call.arguments as int?;
        if (index == null || index < 0 || index >= _results.length) return;
        final (source, novel) = _results[index];
        try {
          await pushToMangaReaderDetail(
            getManga: novel, source: source.name ?? '',
            lang: source.lang ?? '', sourceId: source.id,
            itemType: widget.itemType, ref: ref, context: context,
          );
        } catch (e) {
          if (mounted) await _channel?.invokeMethod<void>('error', e.toString());
        }
    }
  }

  Future<void> _refresh() async {
    if (_loading) return;
    _generation++;
    _results.clear();
    _lastPages.clear();
    _hasMore.clear();
    for (final source in _sources) {
      if (source.id != null) _hasMore.add(source.id!);
    }
    await _fetch(next: false);
  }

  Future<void> _fetch({required bool next}) async {
    if (!mounted || _loading) return;
    _loading = true;
    final serial = _generation;
    setState(() {});
    final sources = [
      for (final source in _sources)
        if (source.id != null && _hasMore.contains(source.id!)) source,
    ];
    var failureCount = 0;
    String? lastError;
    try {
      // Bound concurrency to the same three-isolate limit as the existing
      // Flutter global search; also keep failed sources out of future pages.
      for (var i = 0; i < sources.length; i += 3) {
        if (!mounted || serial != _generation) break;
        final batch = sources.skip(i).take(3);
        await Future.wait(batch.map((source) async {
          final id = source.id!;
          final page = (_lastPages[id] ?? 0) + 1;
          try {
            final MPages? data = query.isEmpty
                ? await ref.read(getPopularProvider(source: source, page: page).future)
                : await ref.read(searchProvider(
                    source: source, page: page, query: query,
                    filterList: const [],
                  ).future);
            if (!mounted || serial != _generation) return;
            _lastPages[id] = page;
            if (data == null || !data.hasNextPage || data.list.isEmpty) {
              _hasMore.remove(id);
            }
            if (data != null) {
              for (final novel in data.list) {
                _results.add((source, novel));
              }
            }
          } catch (error) {
            failureCount++;
            lastError = error.toString();
            _hasMore.remove(id);
          }
        }));
        if (mounted && serial == _generation) setState(() {});
      }
      if (_results.isEmpty && failureCount > 0 && mounted) {
        await _channel?.invokeMethod<void>('error',
            'Unable to search sources: ' + (lastError ?? 'Unknown error'));
      }
    } finally {
      _loading = false;
      if (mounted && serial == _generation) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final sources = _sources;
    _snapshot = {
      'title': 'Global Search',
      'globalMode': true,
      'query': query,
      'loading': _loading,
      'hasMore': _hasMore.isNotEmpty,
      'items': <Map<String, Object?>>[
        for (final (source, novel) in _results)
          {
            'title': novel.name ?? 'Novel',
            'description': novel.author ?? novel.description ?? '',
            'source': source.name ?? 'Unknown source',
          },
      ],
      if (sources.isEmpty) 'emptyMessage':
          'No novel sources are available. Install one from Browse.',
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _channel != null) {
        unawaited(_channel!.invokeMethod<void>('update', _snapshot));
      }
    });
    return UiKitView(
      viewType: 'novayomi/native-source-results',
      creationParams: _snapshot,
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: _created,
    );
  }
}
