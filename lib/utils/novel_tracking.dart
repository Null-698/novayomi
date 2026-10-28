import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/track.dart';

/// Light novels use reading, not anime/watch endpoints, in supported trackers.
bool isReadingTrackerItemType(ItemType? type) =>
    type == ItemType.novel || type == ItemType.manga;

/// Preserve legacy provider identifiers in the database, but only expose
/// providers with a novel-compatible reading catalog.
bool isSupportedNovelTracker(int? syncId) =>
    syncId == TrackerProviders.myAnimeList.syncId ||
    syncId == TrackerProviders.anilist.syncId ||
    syncId == TrackerProviders.kitsu.syncId;
