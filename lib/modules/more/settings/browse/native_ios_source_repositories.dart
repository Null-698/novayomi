import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/settings.dart';
import 'package:mangayomi/modules/more/settings/browse/providers/browse_state_provider.dart';
import 'package:mangayomi/modules/more/settings/browse/source_repositories.dart';
import 'package:mangayomi/repositories/source_repository.dart';
import 'package:mangayomi/services/fetch_item_sources.dart';

/// UIKit presentation with original repository/extension lifecycle.
class NativeIosSourceRepositories extends ConsumerStatefulWidget {
  const NativeIosSourceRepositories({super.key, required this.itemType});
  final ItemType itemType;
  @override
  ConsumerState<NativeIosSourceRepositories> createState() => _NativeIosSourceRepositoriesState();
}

class _NativeIosSourceRepositoriesState extends ConsumerState<NativeIosSourceRepositories> {
  MethodChannel? channel;
  Map<String, Object?> snapshot = const {};
  @override
  void dispose() {
    channel?.setMethodCallHandler(null);
    super.dispose();
  }
  void created(int id) {
    channel = MethodChannel('novayomi/native-preferences/$id');
    channel!.setMethodCallHandler(handle);
    unawaited(channel!.invokeMethod<void>('update', snapshot));
  }
  List<Repo> get repos => ref.read(extensionsRepoStateProvider(widget.itemType));
  Future<void> refresh() async {
    final provider = fetchItemSourcesListProvider(id: null, reFresh: true, itemType: widget.itemType);
    ref.invalidate(provider);
    await ref.read(provider.future);
  }
  Future<void> handle(MethodCall call) async {
    if (!mounted) return;
    try {
      switch (call.method) {
        case 'close':
          if (context.canPop()) context.pop();
        case 'action':
          final id = call.arguments as String?;
          if (id == 'refresh') {
            await refresh();
          } else if (id != null && id.startsWith('remove:')) {
            final i = int.tryParse(id.substring(7));
            final entries = repos;
            if (i == null || i < 0 || i >= entries.length) return;
            final removed = entries[i];
            await ref.read(extensionsRepoStateProvider(widget.itemType).notifier)
                .set([for (var n = 0; n < entries.length; n++) if (n != i) entries[n]]);
            final orphanIds = sourceRepository.getByItemType(widget.itemType)
                .where((e) => e.repo?.jsonUrl == removed.jsonUrl &&
                    (e.sourceCode?.isEmpty ?? true))
                .map((e) => e.id).whereType<int>().toList();
            if (orphanIds.isNotEmpty) await sourceRepository.deleteAll(orphanIds);
          }
        case 'change':
          final args = call.arguments;
          if (args is! Map) return;
          final id = args['id'] as String?;
          final value = args['value'];
          if (id == 'addRepo') {
            final url = (value as String? ?? '').trim();
            final uri = Uri.tryParse(url);
            if (uri == null || !uri.isAbsolute || (uri.scheme != 'http' && uri.scheme != 'https')) {
              throw const FormatException('Enter a valid http(s) extension index URL.');
            }
            if (ref.read(extensionsRepoStateProvider(widget.itemType).notifier).containsRepo(url)) {
              throw const FormatException('Repository already exists.');
            }
            final candidate = await ref.read(getRepoInfosProvider(jsonUrl: url).future);
            if (candidate == null) throw const FormatException('Unsupported repository format.');
            if (repos.any((e) => e.jsonUrl?.trim().toLowerCase() ==
                candidate.jsonUrl?.trim().toLowerCase())) {
              throw const FormatException('Repository already exists.');
            }
            await ref.read(extensionsRepoStateProvider(widget.itemType).notifier)
                .set([...repos, candidate]);
          } else if (id != null && id.startsWith('visible:')) {
            final i = int.tryParse(id.substring(8));
            final entries = repos;
            if (i == null || i < 0 || i >= entries.length) return;
            ref.read(extensionsRepoStateProvider(widget.itemType).notifier)
                .setVisibility(entries[i], value != true);
          }
      }
    } catch (e, st) {
      debugPrint('Native source repositories: $e');
      debugPrintStack(stackTrace: st);
      if (mounted) await channel?.invokeMethod<void>('error', e.toString());
    }
  }
  @override
  Widget build(BuildContext context) {
    final entries = ref.watch(extensionsRepoStateProvider(widget.itemType));
    final counts = ref.watch(repoSourceCountsProvider(widget.itemType)).asData?.value ??
        const <String?, int>{};
    snapshot = {
      'title': 'Novel repositories',
      'sections': <Map<String, Object?>>[
        {
          'title': 'Installed repositories',
          'footer': 'Hidden repositories remain installed, but are excluded from Browse.',
          'rows': <Map<String, Object?>>[
            for (var i = 0; i < entries.length; i++) ...[
              {
                'id': 'visible:$i', 'type': 'toggle',
                'title': entries[i].name ?? entries[i].jsonUrl ?? 'Repository',
                'detail': (counts[entries[i].jsonUrl] ?? 0).toString() +
                    ' sources · ' + (entries[i].jsonUrl ?? ''),
                'symbol': 'shippingbox',
                'value': !(entries[i].hidden ?? false),
              },
              {
                'id': 'remove:$i', 'type': 'action', 'destructive': true,
                'title': 'Remove ' + (entries[i].name ?? 'repository'),
                'detail': 'Preserves installed extensions; removes uninstalled entries.',
                'symbol': 'trash',
              }
            ],
          ],
        },
        {
          'title': 'Manage',
          'rows': <Map<String, Object?>>[
            {'id': 'addRepo', 'type': 'text', 'title': 'Add repository URL',
              'value': '', 'symbol': 'plus.circle'},
            {'id': 'refresh', 'type': 'action', 'title': 'Refresh repository sources',
              'symbol': 'arrow.clockwise'},
          ],
        },
      ],
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && channel != null) {
        unawaited(channel!.invokeMethod<void>('update', snapshot));
      }
    });
    return UiKitView(
      viewType: 'novayomi/native-preferences',
      creationParams: snapshot,
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: created,
    );
  }
}
