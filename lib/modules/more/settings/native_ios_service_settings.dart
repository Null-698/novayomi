import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangayomi/models/track.dart';
import 'package:mangayomi/models/track_preference.dart';
import 'package:mangayomi/modules/more/settings/track/providers/track_providers.dart';
import 'package:mangayomi/modules/more/settings/sync/providers/sync_providers.dart';
import 'package:mangayomi/modules/more/settings/sync/providers/sync_connection_status_provider.dart';
import 'package:mangayomi/modules/more/settings/sync/providers/sync_progress_provider.dart';
import 'package:mangayomi/providers/l10n_providers.dart';
import 'package:mangayomi/repositories/track_repository.dart';
import 'package:mangayomi/services/sync_server.dart';
import 'package:mangayomi/services/trackers/anilist.dart';
import 'package:mangayomi/services/trackers/kitsu.dart';
import 'package:mangayomi/services/trackers/myanimelist.dart';

/// UIKit tracker/sync presentation with original OAuth, login and sync engines.
class NativeIosServiceSettings extends ConsumerStatefulWidget {
  const NativeIosServiceSettings({super.key, required this.mode});
  final String mode; // tracking or sync
  @override
  ConsumerState<NativeIosServiceSettings> createState() => _NativeIosServiceSettingsState();
}

class _NativeIosServiceSettingsState extends ConsumerState<NativeIosServiceSettings> {
  MethodChannel? _channel;
  Map<String, Object?> _snapshot = const {};
  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }
  void _created(int id) {
    final channel = MethodChannel('novayomi/native-preferences/$id');
    _channel = channel;
    channel.setMethodCallHandler(_handle);
    unawaited(channel.invokeMethod<void>('update', _snapshot));
  }

  Future<void> _handle(MethodCall call) async {
    if (!mounted) return;
    try {
      if (call.method == 'close') {
        if (context.canPop()) context.pop();
        return;
      }
      if (call.method == 'navigate') {
        final path = call.arguments as String?;
        if (path != null) context.push(path);
        return;
      }
      if (call.method == 'credentials') {
        final args = call.arguments;
        if (args is! Map || args['id'] != 'kitsu') return;
        final email = (args['username'] as String? ?? '').trim();
        final password = args['password'] as String? ?? '';
        if (email.isEmpty || password.isEmpty) {
          throw const FormatException('Kitsu username and password are required.');
        }
        final result = await ref.read(kitsuProvider(
          syncId: TrackerProviders.kitsu.syncId, widgetRef: ref,
        ).notifier).login(email, password);
        if (!result.$1) throw StateError(result.$2);
        return;
      }
      if (call.method == 'change') {
        final args = call.arguments;
        if (args is! Map) return;
        final id = args['id'] as String?;
        final value = args['value'];
        if (id == 'trackProgress') {
          ref.read(updateProgressAfterReadingStateProvider.notifier)
              .set(value == true);
        } else if (id == 'syncEnabled') {
          final enabled = value == true;
          if (!(ref.read(synchingProvider(syncId: 1)).authToken?.isNotEmpty ?? false)) {
            throw StateError('Connect to a sync server before enabling synchronization.');
          }
          final notifier = ref.read(synchingProvider(syncId: 1).notifier);
          notifier.setSyncOn(enabled);
          if (!enabled) notifier.setAutoSyncFrequency(0);
        } else if (id == 'syncFrequency') {
          final frequency = int.tryParse(value.toString());
          const choices = [0, 300, 600, 1800, 3600, 10800, 21600, 43200];
          if (frequency != null && choices.contains(frequency) &&
              ref.read(synchingProvider(syncId: 1)).syncOn) {
            ref.read(synchingProvider(syncId: 1).notifier)
                .setAutoSyncFrequency(frequency);
          }
        } else if (id == 'syncServer') {
          final server = (value as String? ?? '').trim();
          final uri = Uri.tryParse(server);
          if (uri == null || !uri.isAbsolute ||
              (uri.scheme != 'http' && uri.scheme != 'https')) {
            throw const FormatException('Enter a valid server URL.');
          }
          final result = await ref.read(syncServerProvider(syncId: 1).notifier)
              .login(l10nLocalizations(context)!, server);
          if (!result.$1) throw StateError(result.$2);
        }
        return;
      }
      if (call.method != 'action') return;
      final id = call.arguments as String?;
      switch (id) {
        case 'connectAnilist':
          await ref.read(anilistProvider(
            syncId: TrackerProviders.anilist.syncId, widgetRef: ref,
          ).notifier).login();
        case 'connectMal':
          await ref.read(myAnimeListProvider(
            syncId: TrackerProviders.myAnimeList.syncId,
            itemType: null, widgetRef: ref,
          ).notifier).login();
        case 'disconnectAnilist':
          ref.read(tracksProvider(syncId: TrackerProviders.anilist.syncId).notifier).logout();
        case 'disconnectKitsu':
          ref.read(tracksProvider(syncId: TrackerProviders.kitsu.syncId).notifier).logout();
        case 'disconnectMal':
          ref.read(tracksProvider(syncId: TrackerProviders.myAnimeList.syncId).notifier).logout();
        case 'syncLogOut':
          ref.read(synchingProvider(syncId: 1).notifier).logout();
        case 'syncStatus':
          ref.read(syncConnectionStateProvider(syncId: 1).notifier).recheck();
        case 'syncNow':
          ref.read(syncServerProvider(syncId: 1).notifier)
              .startSync(l10nLocalizations(context)!, false);
        case 'syncUpload':
          ref.read(syncServerProvider(syncId: 1).notifier)
              .startSync(l10nLocalizations(context)!, false, upload: true, download: false);
        case 'syncDownload':
          ref.read(syncServerProvider(syncId: 1).notifier)
              .startSync(l10nLocalizations(context)!, false, upload: false, download: true);
      }
    } catch (e, st) {
      debugPrint('Native service settings error: $e');
      debugPrintStack(stackTrace: st);
      if (mounted) await _channel?.invokeMethod<void>('error', e.toString());
    }
  }
  Map<String, Object?> entry(String id, String title, String kind, {
    Object? value, String? detail, bool destructive = false,
  }) => {
    'id': id, 'title': title, 'type': kind,
    if (value != null) 'value': value,
    if (detail != null) 'detail': detail,
    if (destructive) 'destructive': true,
  };

  Widget _frame({List<TrackPreference>? trackEntries}) {
    final sections = <Map<String, Object?>>[];
    final sync = widget.mode == 'sync';
    if (sync) {
      final account = ref.watch(synchingProvider(syncId: 1));
      final connection = ref.watch(syncConnectionStateProvider(syncId: 1));
      final progress = ref.watch(syncProgressProvider(syncId: 1));
      final logged = account.authToken?.isNotEmpty ?? false;
      final allowed = logged && account.syncOn &&
          connection == SyncConnectionStatus.connected && !progress.active;
      sections.add({
        'title': 'Account',
        'rows': [
          entry('syncServer', logged ? 'Change sync server' : 'Connect to a sync server',
              'text', value: account.server ?? '',
              detail: 'Opens the existing server OAuth login in your browser.'),
          if (logged) ...[
            entry('syncStatus', 'Connection status: ' + connection.name,
                'action', detail: account.server ?? ''),
            entry('syncLogOut', 'Disconnect', 'action', destructive: true),
          ],
        ],
      });
      sections.add({
        'title': 'Synchronization',
        'rows': [
          entry('syncEnabled', 'Enable sync', 'toggle', value: account.syncOn && logged,
              detail: logged ? null : 'Connect to a server first'),
          entry('syncFrequency', 'Automatic sync', 'choice',
            value: account.autoSyncFrequency.toString(),
            detail: 'Select how often to synchronize',
          )..addAll({
            'display': account.autoSyncFrequency == 0 ? 'Off' :
                (account.autoSyncFrequency ~/ 60).toString() + ' min',
            'choices': [
              for (final seconds in [0, 300, 600, 1800, 3600, 10800, 21600, 43200])
                {'value': seconds.toString(),
                 'title': seconds == 0 ? 'Off' :
                     (seconds ~/ 60).toString() + ' minutes'},
            ]
          }),
          if (account.lastSync != null)
            entry('syncStatus', 'Last synchronization',
                'action', detail: DateTime.fromMillisecondsSinceEpoch(account.lastSync!).toString()),
          if (allowed) ...[
            entry('syncNow', 'Sync now', 'action'),
            entry('syncUpload', 'Upload local data', 'action', destructive: true,
              detail: 'Replaces the remote copy with local data.'),
            entry('syncDownload', 'Download remote data', 'action', destructive: true,
              detail: 'Replaces the local copy with server data.'),
          ],
          if (progress.active)
            entry('syncStatus', 'Sync in progress', 'action',
              detail: progress.fraction == null ? 'Working...' :
                  (progress.fraction! * 100).round().toString() + '%'),
        ],
      });
    } else {
      sections.add({
        'title': 'Reading progress',
        'rows': [
          entry('trackProgress', 'Update trackers after reading', 'toggle',
              value: ref.watch(updateProgressAfterReadingStateProvider)),
        ],
      });
      final services = [
        ('AniList', TrackerProviders.anilist.syncId, 'connectAnilist', 'disconnectAnilist'),
        ('Kitsu', TrackerProviders.kitsu.syncId, 'kitsu', 'disconnectKitsu'),
        ('MyAnimeList', TrackerProviders.myAnimeList.syncId, 'connectMal', 'disconnectMal'),
      ];
      sections.add({
        'title': 'Tracking services',
        'footer': 'Account authentication stays with the existing tracker providers.',
        'rows': [
          for (final (name, id, connect, disconnect) in services) ...[
            entry(connect, name,
                connect == 'kitsu' ? 'credentials' : 'action',
                detail: trackEntries?.where((e) => e.syncId == id)
                        .map((e) => e.displayName ?? e.username ?? 'Connected')
                        .firstOrNull ?? 'Connect account'),
            if (trackEntries?.any((e) => e.syncId == id) ?? false)
              entry(disconnect, 'Disconnect ' + name, 'action', destructive: true),
          ],
          entry('/manageTrackers', 'Manage trackers', 'link'),
        ],
      });
    }
    _snapshot = {
      'title': sync ? 'Synchronization' : 'Tracking',
      'sections': sections,
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _channel != null) {
        unawaited(_channel!.invokeMethod<void>('update', _snapshot));
      }
    });
    return UiKitView(
      viewType: 'novayomi/native-preferences',
      creationParams: _snapshot,
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: _created,
    );
  }
  @override
  Widget build(BuildContext context) {
    if (widget.mode != 'tracking') return _frame();
    return StreamBuilder<List<TrackPreference>>(
      stream: trackRepository.watchAllWithSyncId(),
      builder: (context, snapshot) => _frame(trackEntries: snapshot.data ?? const []),
    );
  }
}
