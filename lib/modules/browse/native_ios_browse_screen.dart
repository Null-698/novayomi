import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/modules/browse/sources/sources_screen.dart';
import 'package:mangayomi/modules/browse/extension/providers/extensions_provider.dart';
import 'package:mangayomi/services/fetch_item_sources.dart';
import 'package:mangayomi/services/fetch_sources_list.dart';
import 'package:mangayomi/modules/more/settings/browse/providers/browse_state_provider.dart';
import 'package:mangayomi/repositories/source_repository.dart';

/// The root iOS Browse tab is UIKit. All source installation, filtering and
/// extension execution still use existing Dart services and routes.
class NativeIosBrowseScreen extends ConsumerStatefulWidget {
  const NativeIosBrowseScreen({super.key, this.initialSegment = 0});
  final int initialSegment;

  @override
  ConsumerState<NativeIosBrowseScreen> createState() => _NativeIosBrowseScreenState();
}

class _NativeIosBrowseScreenState extends ConsumerState<NativeIosBrowseScreen> {
  MethodChannel? _channel;
  Map<String, Object?> _current = const {};
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(ref.read(fetchItemSourcesListProvider(
        id: null, reFresh: false, itemType: ItemType.novel,
      ).future).catchError((Object error) {
        debugPrint('Native extension catalog update: $error');
      }));
    });
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  void _created(int id) {
    _channel = MethodChannel('novayomi/native-browse/$id');
    _channel?.setMethodCallHandler(_handleAction);
    unawaited(_channel!.invokeMethod<void>('update', _current));
  }

  Future<void> _handleAction(MethodCall call) async {
    if (!mounted) return;
    switch (call.method) {
      case 'close':
        if (context.canPop()) context.pop();
      case 'openSource':
        final id = call.arguments as int?;
        if (id == null) return;
        final source = sourceRepository.getById(id);
        if (source == null || source.itemType != ItemType.novel) return;
        context.push('/mangaHome', extra: (source, false));
      case 'pin':
        final id = call.arguments as int?;
        if (id == null) return;
        final source = sourceRepository.getById(id);
        if (source == null || source.itemType != ItemType.novel) return;
        source.isPinned = !(source.isPinned ?? false);
        await sourceRepository.save(source);
      case 'openExtension':
        final id = call.arguments as int?;
        if (id == null) return;
        final source = sourceRepository.getById(id);
        if (source?.itemType != ItemType.novel) return;
        context.push('/extension_detail', extra: source);
      case 'updateExtension':
        final id = call.arguments as int?;
        if (id == null) return;
        await ref.read(fetchItemSourcesListProvider(
          id: id, reFresh: true, itemType: ItemType.novel,
        ).future);
      case 'uninstallExtension':
        final id = call.arguments as int?;
        if (id == null) return;
        final source = sourceRepository.getById(id);
        if (source?.itemType != ItemType.novel) return;
        await sourceRepository.uninstall(source!);
      case 'action':
        final action = call.arguments as String?;
        switch (action) {
          case 'extensions':
            await ref.read(fetchItemSourcesListProvider(
              id: null, reFresh: true, itemType: ItemType.novel,
            ).future);
          case 'repositories':
            context.push('/SourceRepositories', extra: ItemType.novel);
          case 'sourceFilters':
            context.push('/sourceFilter', extra: ItemType.novel);
          case 'globalSearch':
            context.push('/globalSearch', extra: (null, ItemType.novel));
          case 'local':
            context.push('/mangaHome',
              extra: (Source(name: 'local', lang: '', itemType: ItemType.novel), false));
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final showNsfw = ref.watch(showNSFWStateProvider);
    final data = ref.watch(getSourcesStreamProvider(ItemType.novel)).asData?.value
        ?? const <Source>[];
    final extensions = ref.watch(getExtensionsStreamProvider(ItemType.novel)).asData?.value
        ?? const <Source>[];
    _current = <String, Object?>{
      'initialSegment': widget.initialSegment,
      'extensions': <Map<String, Object?>>[
        for (final extension in extensions)
          if (extension.id != null && (showNsfw || !(extension.isNsfw ?? false)) &&
              !(extension.repo?.hidden ?? false))
            {
              'id': extension.id!,
              'name': extension.name ?? 'Extension',
              'icon': extension.iconUrl ?? '',
              'lang': extension.lang ?? '',
              'installed': extension.isAdded ?? false,
              'version': extension.version ?? '',
              'updateAvailable': (extension.isAdded ?? false) &&
                  !(extension.isObsolete ?? false) &&
                  compareVersions(extension.version ?? '', extension.versionLast ?? '') < 0,
            },
      ],
      'sources': <Map<String, Object?>>[
        for (final source in data)
          if (source.id != null && (showNsfw || !(source.isNsfw ?? false)))
            {
              'id': source.id,
              'name': source.name ?? 'Source',
              'icon': source.iconUrl ?? '',
              'lang': source.lang ?? '',
              'pinned': source.isPinned ?? false,
              'lastUsed': source.lastUsed ?? false,
            }
      ],
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _channel != null) {
        unawaited(_channel!.invokeMethod<void>('update', _current));
      }
    });
    return UiKitView(
      viewType: 'novayomi/native-browse',
      creationParams: _current,
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: _created,
    );
  }
}
