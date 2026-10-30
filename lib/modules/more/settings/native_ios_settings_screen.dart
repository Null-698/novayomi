import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

/// The settings list/search UI is UIKit. Destination settings continue using
/// the existing Dart providers until each form is converted.
class NativeIosSettingsScreen extends StatefulWidget {
  const NativeIosSettingsScreen({super.key});

  @override
  State<NativeIosSettingsScreen> createState() => _NativeIosSettingsScreenState();
}

class _NativeIosSettingsScreenState extends State<NativeIosSettingsScreen> {
  MethodChannel? _channel;

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  void _created(int id) {
    final channel = MethodChannel('novayomi/native-settings/$id');
    _channel = channel;
    channel.setMethodCallHandler((call) async {
      if (!mounted) return;
      switch (call.method) {
        case 'close':
          if (context.canPop()) context.pop();
        case 'navigate':
          final path = call.arguments as String?;
          if (path != null) context.push(path);
      }
    });
  }

  @override
  Widget build(BuildContext context) => UiKitView(
    viewType: 'novayomi/native-settings',
    creationParams: const <String, Object?>{},
    creationParamsCodec: const StandardMessageCodec(),
    onPlatformViewCreated: _created,
  );
}
