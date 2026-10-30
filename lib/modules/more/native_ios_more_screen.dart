import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/modules/more/more_screen.dart';
import 'package:mangayomi/modules/more/providers/downloaded_only_state_provider.dart';
import 'package:mangayomi/modules/more/providers/incognito_mode_state_provider.dart';
import 'package:mangayomi/providers/reader_state_provider.dart';
import 'package:mangayomi/router/router.dart';

/// Native UIKit More interface. Existing Riverpod settings and routes remain
/// the only sources of truth. No native preference or database backend.
class NativeIosMoreScreen extends ConsumerStatefulWidget {
  const NativeIosMoreScreen({super.key});

  @override
  ConsumerState<NativeIosMoreScreen> createState() => _NativeIosMoreScreenState();
}

class _NativeIosMoreScreenState extends ConsumerState<NativeIosMoreScreen> {
  MethodChannel? _channel;
  Map<String, Object?> _current = const {};

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  void _created(int id) {
    _channel = MethodChannel('novayomi/native-more/$id');
    _channel?.setMethodCallHandler(_handleNative);
    unawaited(_channel!.invokeMethod<void>('update', _current));
  }

  Future<void> _handleNative(MethodCall call) async {
    if (!mounted) return;
    switch (call.method) {
      case 'navigate':
        final path = call.arguments as String?;
        if (path == null) return;
        if (path == '/categories') {
          context.push(path, extra: (false, 0));
        } else if (path == '/massMigration') {
          context.push(path, extra: (ItemType.novel, null));
        } else {
          context.push(path);
        }
      case 'mode':
        final args = call.arguments;
        if (args is! Map) return;
        final value = args['value'] as bool?;
        if (value == null) return;
        switch (args['name']) {
          case 'downloadedOnly':
            ref.read(downloadedOnlyStateProvider.notifier).setDownloadedOnly(value);
          case 'incognito':
            ref.read(incognitoModeStateProvider.notifier).setIncognitoMode(value);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String?>(routerCurrentLocationStateProvider, (_, path) {
      if (path == '/more') ref.invalidate(readingSummaryProvider);
    });
    final summary = ref.watch(readingSummaryProvider).asData?.value;
    _current = <String, Object?>{
      'downloadedOnly': ref.watch(downloadedOnlyStateProvider),
      'incognito': ref.watch(incognitoModeStateProvider),
      'showHistory': ref.watch(hideItemsStateProvider).contains('/history'),
      'series': summary?.$1 ?? 0,
      'read': summary?.$2 ?? 0,
      'seconds': summary?.$3 ?? 0,
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _channel != null) {
        unawaited(_channel!.invokeMethod<void>('update', _current));
      }
    });
    return UiKitView(
      viewType: 'novayomi/native-more',
      creationParams: _current,
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: _created,
    );
  }
}
