import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:file_picker/file_picker.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/auto_backup.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/backup.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/backup_compression.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/backup_encryption.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/storage_usage.dart';
import 'package:mangayomi/modules/more/data_and_storage/widgets/unified_restore.dart';
import 'package:mangayomi/modules/more/settings/downloads/providers/downloads_state_provider.dart';
import 'package:mangayomi/providers/storage_provider.dart';
import 'package:mangayomi/services/backup_password_storage.dart';

/// UIKit backup and storage presentation, retaining the existing archive,
/// restore, database transactions, password storage and provider logic.
class NativeIosDataStorage extends ConsumerStatefulWidget {
  const NativeIosDataStorage({super.key, this.createBackup = false});
  final bool createBackup;
  @override
  ConsumerState<NativeIosDataStorage> createState() => _NativeIosDataStorageState();
}

class _NativeIosDataStorageState extends ConsumerState<NativeIosDataStorage> {
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
      switch (call.method) {
        case 'close':
          if (context.canPop()) context.pop();
        case 'navigate':
          final path = call.arguments as String?;
          if (path != null) context.push(path);
        case 'secret':
          final args = call.arguments;
          if (args is! Map || args['id'] != 'backupPassword') return;
          final password = args['value'] as String? ?? '';
          if (password.isEmpty) throw const FormatException('Backup password cannot be empty');
          await BackupPasswordStorage.save(password);
          await ref.read(backupEncryptionEnabledProvider.notifier).set(true);
        case 'action':
          final id = call.arguments as String?;
          switch (id) {
            case 'restore':
              // The original validated restore flow retains merge/replace,
              // cross-format warnings and rollback safeguards. Never bypass it.
              await performRestore(context, ref);
            case 'create':
              final selected = ref.read(backupFrequencyOptionsStateProvider);
              if (selected.isEmpty) throw StateError('Select backup content first.');
              final folder = await StorageProvider().getIosBackupDirectory();
              if (folder == null || !mounted) throw StateError('iOS backup directory unavailable');
              ref.read(doBackUpProvider(list: selected, path: folder.path, context: context));
            case 'clearCache':
              await ref.read(totalChapterCacheSizeStateProvider.notifier).clearCache();
            case 'disableEncryption':
              await ref.read(backupEncryptionEnabledProvider.notifier).set(false);
              await BackupPasswordStorage.clear();
            case 'resetDownloadLocation':
              ref.read(downloadLocationStateProvider.notifier).set('');
            case 'chooseDownloadLocation':
              final path = await FilePicker.getDirectoryPath();
              if (path != null) ref.read(downloadLocationStateProvider.notifier).set(path);
          }
        case 'change':
          final args = call.arguments;
          if (args is! Map) return;
          final id = args['id'] as String?;
          final value = args['value'];
          if (id == null) return;
          if (id.startsWith('part:')) {
            final index = int.tryParse(id.substring(5));
            if (index == null) return;
            final options = ref.read(backupFrequencyOptionsStateProvider);
            ref.read(backupFrequencyOptionsStateProvider.notifier)
                .set(value == true
                    ? {...options, index}.toList()..sort()
                    : options.where((e) => e != index).toList());
          } else if (id == 'backupFrequency') {
            final freq = int.tryParse(value.toString());
            if (freq != null && freq >= 0 && freq <= 5) {
              ref.read(backupFrequencyStateProvider.notifier).set(freq);
            }
          } else if (id == 'compression') {
            final v = (value as num).round().clamp(0, 9);
            await ref.read(backupCompressionLevelProvider.notifier).set(v);
          } else if (id == 'clearOnLaunch') {
            ref.read(clearChapterCacheOnAppLaunchStateProvider.notifier).set(value == true);
          }
      }
    } catch (error, stack) {
      debugPrint('Native backup/storage error: $error');
      debugPrintStack(stackTrace: stack);
      if (mounted) await channel?.invokeMethod<void>('error', error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final sections = <Map<String, Object?>>[];
    if (widget.createBackup) {
      final options = ref.watch(backupFrequencyOptionsStateProvider);
      for (final (name, items) in [
        ('Library', <(String, int)>[
          ('Novel entries', 0), ('Categories', 1), ('Chapters', 2),
          ('Tracking', 3), ('History', 4), ('Updates', 5),
        ]),
        ('Preferences', <(String, int)>[
          ('App settings', 6), ('Source settings', 7),
          ('Sensitive settings', 8), ('Custom buttons', 10),
        ]),
        ('Extensions', <(String, int)>[('Installed extensions', 9)]),
      ]) {
        sections.add({
          'title': name,
          'rows': [
            for (final (label, index) in items)
              {'id': 'part:$index', 'type': 'toggle', 'title': label,
               'value': options.contains(index)},
          ],
        });
      }
      sections.add({
        'title': 'Create',
        'footer': 'The selected data will be archived using the existing backup format.',
        'rows': [
          {'id': 'create', 'type': 'action', 'title': 'Create backup now',
           'symbol': 'square.and.arrow.down', 'detail':
               options.isEmpty ? 'Select at least one category' :
                   options.length.toString() + ' selected categories'},
        ],
      });
    } else {
      final freq = ref.watch(backupFrequencyStateProvider);
      final encrypted = ref.watch(backupEncryptionEnabledProvider);
      final path = ref.watch(downloadLocationStateProvider);
      sections.add({
        'title': 'Backup and restore',
        'footer': 'Restore preserves the original import, merge and rollback checks.',
        'rows': [
          {'id': '/createBackup', 'type': 'link', 'title': 'Create backup',
           'symbol': 'square.and.arrow.down'},
          {'id': 'restore', 'type': 'action', 'title': 'Restore from backup',
           'symbol': 'arrow.counterclockwise',
           'detail': 'Choose a backup file and review the import'},
          {'id': 'backupFrequency', 'type': 'choice', 'title': 'Automatic backup',
           'value': freq.toString(), 'display':
               ['Off', 'Every 6 hours', 'Every 12 hours', 'Daily',
                'Every 2 days', 'Weekly'][freq.clamp(0, 5)],
           'choices': [
             for (var i = 0; i < 6; i++)
               {'value': i.toString(), 'title':
                   ['Off', 'Every 6 hours', 'Every 12 hours', 'Daily',
                    'Every 2 days', 'Weekly'][i]},
           ]},
          {'id': 'compression', 'type': 'slider', 'title': 'Backup compression',
           'value': ref.watch(backupCompressionLevelProvider),
           'min': 0, 'max': 9, 'step': 1},
        ],
      });
      sections.add({
        'title': 'Encryption',
        'rows': [
          {'id': 'backupPassword', 'type': 'secret',
           'title': encrypted ? 'Change backup password' : 'Enable encrypted backups',
           'symbol': 'key',
           'detail': 'The password is saved in the iOS Keychain'},
          if (encrypted) {
            'id': 'disableEncryption', 'type': 'action',
            'title': 'Disable backup encryption', 'destructive': true,
            'symbol': 'lock.open',
          }
        ],
      });
      sections.add({
        'title': 'Storage',
        'rows': [
          {'id': 'clearCache', 'type': 'action', 'title': 'Clear chapter cache',
           'symbol': 'trash', 'detail': ref.watch(totalChapterCacheSizeStateProvider)},
          {'id': 'clearOnLaunch', 'type': 'toggle',
           'title': 'Clear cache on app launch',
           'value': ref.watch(clearChapterCacheOnAppLaunchStateProvider)},
          {'id': 'chooseDownloadLocation', 'type': 'action',
           'title': 'Change download location', 'symbol': 'folder',
           'detail': path.$2.isEmpty ? path.$1 : path.$2},
          if (path.$2.isNotEmpty)
            {'id': 'resetDownloadLocation', 'type': 'action',
             'title': 'Reset download location', 'symbol': 'arrow.uturn.backward'},
        ],
      });
    }
    snapshot = {'title': widget.createBackup ? 'Create Backup' : 'Data & Storage',
      'sections': sections};
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
