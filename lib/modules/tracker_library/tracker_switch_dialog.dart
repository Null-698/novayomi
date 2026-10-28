import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangayomi/l10n/generated/app_localizations.dart';
import 'package:mangayomi/models/track.dart';
import 'package:mangayomi/models/track_preference.dart';
import 'package:mangayomi/providers/track_state_providers.dart';
import 'package:mangayomi/utils/constant.dart';
import 'package:shiori/shiori.dart';

/// Switch between connected novel-compatible tracking providers.
void showTrackerSwitchProviderDialog(
  BuildContext context,
  WidgetRef ref, {
  required List<TrackPreference> preferences,
  required AppLocalizations l10n,
}) {
  showDialog(
    context: context,
    builder: (ctx) => ShioriDialog(
      title: l10n.track_library_switch,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final provider in [
            TrackerProviders.myAnimeList,
            TrackerProviders.anilist,
            TrackerProviders.kitsu,
          ])
            ListTile(
              leading: Image.asset(
                trackInfos(provider.syncId).$1,
                width: 36,
                height: 36,
              ),
              title: Text(trackInfos(provider.syncId).$2),
              enabled: preferences.any((p) => p.syncId == provider.syncId),
              onTap: () {
                // Keep the existing serialized location tuple for backups.
                ref.read(lastTrackerLibraryLocationStateProvider.notifier)
                    .set((provider.syncId, true));
                ctx.pop();
              },
            ),
        ],
      ),
    ),
  );
}
