import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:mangayomi/models/track_preference.dart';
import 'package:mangayomi/repositories/track_repository.dart';
import 'package:mangayomi/utils/constant.dart';
import 'package:mangayomi/utils/novel_tracking.dart';

/// Native connected-tracker list; tracking data remains in Isar.
class NativeIosManageTrackers extends StatefulWidget {
  const NativeIosManageTrackers({super.key});
  @override
  State<NativeIosManageTrackers> createState() => _NativeIosManageTrackersState();
}

class _NativeIosManageTrackersState extends State<NativeIosManageTrackers> {
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
    if (call.method == 'close') {
      if (context.canPop()) context.pop();
    } else if (call.method == 'navigate') {
      final id = call.arguments as String?;
      if (id == '/track') {
        context.push('/track');
      } else if (id != null && id.startsWith('tracker:')) {
        final syncId = int.tryParse(id.substring(8));
        if (syncId == null) return;
        final preference = trackRepository.getPreferenceById(syncId);
        if (preference != null && mounted) {
          context.push('/trackingDetail', extra: preference);
        }
      }
    }
  }
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<TrackPreference>>(
      stream: trackRepository.watchAllWithSyncId(),
      builder: (context, data) {
        final entries = [
          for (final pref in data.data ?? trackRepository.getAllPreferences())
            if (pref.syncId != null && isSupportedNovelTracker(pref.syncId))
              pref,
        ];
        snapshot = {
          'title': 'Manage trackers',
          'sections': <Map<String, Object?>>[
            {
              'title': 'Connected reading trackers',
              'rows': <Map<String, Object?>>[
                for (final pref in entries)
                  {
                    'id': 'tracker:' + pref.syncId.toString(),
                    'title': trackInfos(pref.syncId!).$2,
                    'detail': (pref.displayName ?? pref.username ?? 'Connected') +
                        ' · ' + trackRepository.countBySyncId(pref.syncId!).toString() + ' tracked',
                    'type': 'link',
                    'symbol': 'checkmark.seal',
                  },
                if (entries.isEmpty)
                  {
                    'id': '/track', 'type': 'link',
                    'title': 'Connect a tracker',
                    'detail': 'Supported: AniList, Kitsu and MyAnimeList',
                    'symbol': 'plus.circle',
                  },
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
      },
    );
  }
}
