import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/modules/more/settings/browse/providers/browse_state_provider.dart';
import 'package:mangayomi/repositories/source_repository.dart';
import 'package:mangayomi/utils/language.dart';

/// iOS source filter is a UIKit form. Existing source repository owns the
/// active-language and source-added flags, including updatedAt stamps.
class NativeIosSourceFilter extends ConsumerStatefulWidget {
  const NativeIosSourceFilter({super.key, required this.itemType});
  final ItemType itemType;
  @override
  ConsumerState<NativeIosSourceFilter> createState() => _NativeIosSourceFilterState();
}

class _NativeIosSourceFilterState extends ConsumerState<NativeIosSourceFilter> {
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
  Future<void> handle(MethodCall call) async {
    if (!mounted) return;
    try {
      if (call.method == 'close') {
        if (context.canPop()) context.pop();
      } else if (call.method == 'navigate') {
        final path = call.arguments as String?;
        if (path != null) context.push(path);
      } else if (call.method == 'change') {
        final args = call.arguments;
        if (args is! Map) return;
        final id = args['id'] as String?;
        final active = args['value'] == true;
        if (id == null) return;
        if (id.startsWith('source:')) {
          final sourceId = int.tryParse(id.substring(7));
          if (sourceId == null) return;
          final item = sourceRepository.getById(sourceId);
          if (item?.itemType != widget.itemType) return;
          await sourceRepository.save(item!..isAdded = active);
        } else if (id.startsWith('language:')) {
          final language = id.substring(9);
          final now = DateTime.now().millisecondsSinceEpoch;
          final list = sourceRepository.getByItemType(widget.itemType)
              .where((e) => e.lang?.toLowerCase() == language &&
                  e.sourceCode?.isNotEmpty == true)
              .map((e) => e
                ..isActive = active
                ..updatedAt = now)
              .toList();
          if (list.isNotEmpty) await sourceRepository.putAll(list);
        }
      }
    } catch (e, st) {
      debugPrint('Native source filter: $e');
      debugPrintStack(stackTrace: st);
      if (mounted) await channel?.invokeMethod<void>('error', e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final showNSFW = ref.watch(showNSFWStateProvider);
    return StreamBuilder<List<Source>>(
      stream: sourceRepository.watchWithCodeByItemType(widget.itemType),
      builder: (context, data) {
        final filtered = [
          for (final e in data.data ?? const <Source>[])
            if (e.id != null && (showNSFW || !(e.isNsfw ?? false))) e,
        ]..sort((a, b) {
          final lang = (a.lang ?? '').compareTo(b.lang ?? '');
          return lang != 0 ? lang : (a.name ?? '').compareTo(b.name ?? '');
        });
        final codes = <String>{
          for (final source in filtered) (source.lang ?? '').toLowerCase(),
        }.toList()..sort();
        snapshot = {
          'title': 'Source Filters',
          'sections': <Map<String, Object?>>[
            for (final code in codes)
              {
                'title': languageName(context, code),
                'rows': <Map<String, Object?>>[
                  {
                    'id': 'language:$code', 'title': 'Enable language',
                    'type': 'toggle', 'symbol': 'globe',
                    'value': filtered.any((s) =>
                        s.lang?.toLowerCase() == code && (s.isActive ?? false)),
                  },
                  for (final source in filtered)
                    if (source.lang?.toLowerCase() == code)
                      {
                        'id': 'source:' + source.id.toString(),
                        'type': 'toggle',
                        'title': source.name ?? 'Source',
                        'detail': source.isActive == true ?
                            'Visible when enabled' : 'Language disabled',
                        'value': source.isAdded ?? false,
                      },
                ],
              },
            if (codes.isEmpty)
              {'title': 'No installed sources',
               'rows': <Map<String, Object?>>[
                 {'id': '/browse', 'title': 'Install novel extensions in Browse',
                  'type': 'link', 'symbol': 'plus.circle'},
               ]},
          ],
        };
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && channel != null) {
            unawaited(channel!.invokeMethod<void>('update', snapshot));
          }
        });
        return UiKitView(viewType: 'novayomi/native-preferences',
          creationParams: snapshot,
          creationParamsCodec: const StandardMessageCodec(),
          onPlatformViewCreated: created);
      },
    );
  }
}
