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
import 'package:mangayomi/services/get_popular.dart';
import 'package:mangayomi/services/get_latest_updates.dart';
import 'package:mangayomi/services/search.dart';
import 'package:mangayomi/services/get_filter_list.dart';
import 'package:mangayomi/services/get_source_baseurl.dart';
import 'package:mangayomi/utils/headers.dart';

/// Native iOS source result browser backed by the existing extension service,
/// source filters, paging and novel detail lookup.
class NativeIosSourceResults extends ConsumerStatefulWidget {
  const NativeIosSourceResults({super.key, required this.source, this.isLatest = false});
  final Source source;
  final bool isLatest;
  @override
  ConsumerState<NativeIosSourceResults> createState() => _NativeIosSourceResultsState();
}
class _NativeIosSourceResultsState extends ConsumerState<NativeIosSourceResults> {
  MethodChannel? _channel;
  final _items = <MManga>[];
  late int _mode = widget.isLatest ? 1 : 0;
  String _query = '';
  int _page = 0;
  bool _hasMore = true;
  bool _busy = false;
  List<dynamic>? _filters;
  Map<String, Object?> _snapshot = const {};
  @override
  void initState() {
    super.initState();
    unawaited(_load(reset: true));
  }
  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }
  void _created(int id) {
    _channel = MethodChannel('novayomi/native-source-results/$id');
    _channel?.setMethodCallHandler(_handle);
    unawaited(_channel!.invokeMethod<void>('update', _snapshot));
  }

  Future<void> _handle(MethodCall call) async {
    if (!mounted) return;
    try {
      switch (call.method) {
        case 'close':
          if (context.canPop()) context.pop();
        case 'mode':
          _mode = call.arguments == 1 ? 1 : 0;
          _query = '';
          await _load(reset: true);
        case 'search':
          _query = (call.arguments as String? ?? '').trim();
          await _load(reset: true);
        case 'refresh':
          await _load(reset: true);
        case 'loadMore':
          if (!_busy && _hasMore) await _load(reset: false);
        case 'open':
          final index = call.arguments as int?;
          if (index == null || index < 0 || index >= _items.length) return;
          final novel = _items[index];
          if (!mounted) return;
          await pushToMangaReaderDetail(
            getManga: novel, ref: ref, context: context,
            lang: widget.source.lang ?? '', source: widget.source.name ?? '',
            sourceId: widget.source.id, itemType: ItemType.novel,
          );
        case 'settings':
          context.push('/extension_detail', extra: widget.source);
        case 'website':
          final base = ref.read(sourceBaseUrlProvider(source: widget.source));
          context.push('/mangawebview', extra: {
            'url': base, 'sourceId': widget.source.id.toString(),
            'title': widget.source.name ?? '',
          });
      }
    } catch (error, stack) {
      debugPrint('Native source results: $error');
      debugPrintStack(stackTrace: stack);
      if (mounted) await _channel?.invokeMethod<void>('error', '$error');
    }
  }
  Future<void> _load({required bool reset}) async {
    if (!mounted || _busy) return;
    if (!reset && !_hasMore) return;
    _busy = true;
    if (reset) {
      _page = 0;
      _hasMore = true;
      _items.clear();
    }
    if (mounted) setState(() {});
    try {
      final page = _page + 1;
      MPages? result;
      if (_query.isNotEmpty) {
        _filters ??= widget.source.name == 'local' ? [] :
            getFilterList(source: widget.source);
        result = await ref.read(searchProvider(
          source: widget.source, query: _query,
          page: page, filterList: _filters!,
        ).future);
      } else if (_mode == 1) {
        result = await ref.read(getLatestUpdatesProvider(
          source: widget.source, page: page,
        ).future);
      } else {
        result = await ref.read(getPopularProvider(
          source: widget.source, page: page,
        ).future);
      }
      if (!mounted) return;
      if (result != null) {
        _items.addAll(result.list);
        _page = page;
        _hasMore = result.hasNextPage && result.list.isNotEmpty;
      } else {
        _hasMore = false;
      }
    } catch (error) {
      if (mounted) await _channel?.invokeMethod<void>('error', '$error');
    } finally {
      _busy = false;
      if (mounted) setState(() {});
    }
  }
  @override
  Widget build(BuildContext context) {
    final headers = widget.source.name == 'local' ? <String, String>{} :
        ref.watch(headersProvider(
          source: widget.source.name ?? '',
          lang: widget.source.lang ?? '',
          sourceId: widget.source.id,
        ));
    _snapshot = <String, Object?>{
      'title': widget.source.name ?? 'Source',
      'loading': _busy,
      'hasMore': _hasMore,
      'items': <Map<String, Object?>>[
        for (final novel in _items)
          {
            'title': novel.name ?? 'Novel',
            'description': novel.author ?? novel.description ?? '',
            'cover': novel.imageUrl ?? '',
            'headers': headers,
          }
      ],
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
