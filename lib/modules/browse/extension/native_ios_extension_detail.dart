import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangayomi/eval/model/source_preference.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/modules/more/settings/browse/providers/browse_state_provider.dart';
import 'package:mangayomi/repositories/source_repository.dart';
import 'package:mangayomi/services/extension_preferences_service.dart';
import 'package:mangayomi/services/get_source_preference.dart';
import 'package:mangayomi/services/http/m_client.dart';

/// Native extension metadata and dynamic preference form. The extension's
/// declarations are interpreted by the existing backend, then rendered in UIKit.
class NativeIosExtensionDetail extends ConsumerStatefulWidget {
  const NativeIosExtensionDetail({super.key, required this.source});
  final Source source;
  @override
  ConsumerState<NativeIosExtensionDetail> createState() => _NativeIosExtensionDetailState();
}

class _NativeIosExtensionDetailState extends ConsumerState<NativeIosExtensionDetail> {
  MethodChannel? _channel;
  late Source source;
  List<SourcePreference> preferences = [];
  Map<String, Object?> snapshot = const {};

  @override
  void initState() {
    super.initState();
    source = sourceRepository.getById(widget.source.id!) ?? widget.source;
    reloadPreferences();
  }
  void reloadPreferences() {
    try {
      final List<SourcePreference> declared =
          source.sourceCodeLanguage == SourceCodeLanguage.mihon &&
                  source.preferenceList != null
              ? (jsonDecode(source.preferenceList!) as List)
                  .map((e) => SourcePreference.fromJson(e as Map<String, dynamic>)).toList()
              : getSourcePreference(source: source);
      preferences = [
        for (final declaredPref in declared)
          if (declaredPref.key != null)
            getSourcePreferenceEntry(declaredPref.key!, source.id!, source: source),
      ];
    } catch (e) {
      debugPrint('Native extension preferences: $e');
      preferences = [];
    }
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }
  void created(int id) {
    _channel = MethodChannel('novayomi/native-preferences/$id');
    _channel!.setMethodCallHandler(handle);
    unawaited(_channel!.invokeMethod<void>('update', snapshot));
  }
  Future<void> handle(MethodCall call) async {
    if (!mounted) return;
    try {
      switch (call.method) {
        case 'close':
          if (context.canPop()) context.pop(source);
        case 'navigate':
          final path = call.arguments as String?;
          if (path == '/codeEditor') {
            final result = await context.push(path, extra: source.id);
            if (result is Source) {
              source = result;
              reloadPreferences();
              if (mounted) setState(() {});
            }
          } else if (path == '/createExtension') {
            final result = await context.push(path, extra: source);
            if (result is Source) {
              source = result;
              reloadPreferences();
              if (mounted) setState(() {});
            }
          }
        case 'action':
          final name = call.arguments as String?;
          if (name == 'deleteCookies') {
            MClient.deleteAllCookies(source.baseUrl ?? '');
          } else if (name == 'uninstall') {
            await sourceRepository.uninstall(source);
            if (mounted && context.canPop()) context.pop(source);
          }
        case 'change':
          final args = call.arguments;
          if (args is! Map) return;
          final id = args['id'] as String?;
          final value = args['value'];
          if (id == null) return;
          final parts = id.split(':');
          if (parts.length < 2 || parts[0] != 'pref') return;
          final i = int.tryParse(parts[1]);
          if (i == null || i < 0 || i >= preferences.length) return;
          final pref = preferences[i];
          if (parts.length == 3 && pref.multiSelectListPreference != null) {
            final values = pref.multiSelectListPreference!;
            final j = int.tryParse(parts[2]);
            if (j == null || j < 0 || j >= (values.entryValues?.length ?? 0)) return;
            final key = values.entryValues![j];
            final selected = {...?values.values};
            if (value == true) {
              selected.add(key);
            } else {
              selected.remove(key);
            }
            values.values = selected.toList();
          } else if (pref.checkBoxPreference != null) {
            pref.checkBoxPreference!.value = value == true;
          } else if (pref.switchPreferenceCompat != null) {
            pref.switchPreferenceCompat!.value = value == true;
          } else if (pref.editTextPreference != null) {
            pref.editTextPreference!.value = value?.toString() ?? '';
          } else if (pref.listPreference != null) {
            final chosen = int.tryParse(value.toString());
            final options = pref.listPreference!.entries ?? [];
            if (chosen == null || chosen < 0 || chosen >= options.length) return;
            pref.listPreference!.valueIndex = chosen;
          }
          setPreferenceSetting(pref, source);
          if (mounted) setState(() {});
      }
    } catch (e, st) {
      debugPrint('Native extension detail: $e');
      debugPrintStack(stackTrace: st);
      if (mounted) await _channel?.invokeMethod<void>('error', e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = <Map<String, Object?>>[];
    for (var i = 0; i < preferences.length; i++) {
      final pref = preferences[i];
      if (pref.checkBoxPreference case final v?) {
        rows.add({'id': 'pref:$i', 'title': v.title ?? pref.key ?? 'Switch',
          'detail': v.summary ?? '', 'type': 'toggle', 'value': v.value ?? false});
      } else if (pref.switchPreferenceCompat case final v?) {
        rows.add({'id': 'pref:$i', 'title': v.title ?? pref.key ?? 'Switch',
          'detail': v.summary ?? '', 'type': 'toggle', 'value': v.value ?? false});
      } else if (pref.editTextPreference case final v?) {
        rows.add({'id': 'pref:$i', 'title': v.title ?? pref.key ?? 'Text',
          'detail': v.summary ?? v.dialogMessage ?? '',
          'type': 'text', 'value': v.value ?? ''});
      } else if (pref.listPreference case final v?) {
        final options = v.entries ?? const <String>[];
        final current = (v.valueIndex ?? 0).clamp(0, options.isEmpty ? 0 : options.length - 1).toInt();
        rows.add({'id': 'pref:$i', 'title': v.title ?? pref.key ?? 'Option',
          'type': 'choice', 'value': current.toString(),
          'display': options.isEmpty ? '-' : options[current],
          'choices': [
            for (var j = 0; j < options.length; j++)
              {'value': j.toString(), 'title': options[j]},
          ]});
      } else if (pref.multiSelectListPreference case final v?) {
        final options = v.entries ?? const <String>[];
        final selected = v.values ?? const <String>[];
        for (var j = 0; j < options.length; j++) {
          if (j >= (v.entryValues?.length ?? 0)) break;
          rows.add({'id': 'pref:$i:$j', 'type': 'toggle',
            'title': (v.title ?? pref.key ?? 'Multi-select') + ' · ' + options[j],
            'value': selected.contains(v.entryValues![j])});
        }
      }
    }
    snapshot = {
      'title': source.name ?? 'Extension',
      'sections': <Map<String, Object?>>[
        {
          'title': 'Extension',
          'rows': [
            {'id': 'extensionVersion', 'type': 'action',
              'title': source.name ?? 'Source',
              'detail': (source.lang ?? '') + ' · ' + (source.version ?? '')},
            {'id': 'deleteCookies', 'type': 'action',
              'title': 'Clear source cookies', 'symbol': 'trash'},
            if (ref.watch(developerModeStateProvider)) ...[
              {'id': '/codeEditor', 'type': 'link', 'title': 'Edit source code'},
              if (source.isLocal ?? false)
                {'id': '/createExtension', 'type': 'link', 'title': 'Edit source metadata'},
            ],
            {'id': 'uninstall', 'type': 'action', 'title': 'Uninstall extension',
              'destructive': true, 'symbol': 'xmark.circle'},
          ],
        },
        if (rows.isNotEmpty)
          {'title': 'Extension settings', 'rows': rows},
      ],
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _channel != null) {
        unawaited(_channel!.invokeMethod<void>('update', snapshot));
      }
    });
    return UiKitView(viewType: 'novayomi/native-preferences',
      creationParams: snapshot, creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: created);
  }
}
