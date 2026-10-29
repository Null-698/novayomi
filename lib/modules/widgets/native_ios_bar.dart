import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Actual UIKit controls, not a Flutter Liquid Glass lookalike.
/// System appearance comes from UITabBar/UINavigationBar/UIToolbar in the iOS SDK.
class NativeIosBar extends StatefulWidget {
  const NativeIosBar({
    super.key,
    required this.kind,
    required this.data,
    this.onSelected,
    this.onAction,
  });

  final String kind;
  final Map<String, Object?> data;
  final ValueChanged<int>? onSelected;
  final ValueChanged<String>? onAction;

  @override
  State<NativeIosBar> createState() => _NativeIosBarState();
}

class _NativeIosBarState extends State<NativeIosBar> {
  MethodChannel? _channel;

  @override
  void didUpdateWidget(covariant NativeIosBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateNative();
  }

  void _updateNative() {
    _channel?.invokeMethod<void>('update', <String, Object?>{
      'kind': widget.kind,
      ...widget.data,
    });
  }

  void _onCreated(int id) {
    final channel = MethodChannel('novayomi/native-bar/$id');
    _channel = channel;
    channel.setMethodCallHandler((call) async {
      if (!mounted) return;
      if (call.method == 'select' && call.arguments is int) {
        widget.onSelected?.call(call.arguments as int);
      } else if (call.method == 'action' && call.arguments is String) {
        widget.onAction?.call(call.arguments as String);
      }
    });
    _updateNative();
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    _channel = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    assert(defaultTargetPlatform == TargetPlatform.iOS);
    return UiKitView(
      viewType: 'novayomi/native-bar',
      creationParams: <String, Object?>{
        'kind': widget.kind,
        ...widget.data,
      },
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: _onCreated,
    );
  }
}

/// SF Symbols for the existing GoRouter destinations.
String nativeNavigationSymbol(String route) {
  switch (route) {
    case '/NovelLibrary':
      return 'books.vertical';
    case '/MangaLibrary':
      return 'book';
    case '/AnimeLibrary':
      return 'play.rectangle';
    case '/history':
      return 'clock.arrow.circlepath';
    case '/updates':
      return 'bell.badge';
    case '/browse':
      return 'safari';
    case '/more':
      return 'ellipsis';
    case '/trackerLibrary':
      return 'point.3.connected.trianglepath.dotted';
    case '_disableLibSwitch':
      return 'chevron.backward';
    case '_enableLibSwitch':
    case 'library':
      return 'books.vertical';
    case 'activity':
      return 'bell';
    default:
      return 'square.grid.2x2';
  }
}
