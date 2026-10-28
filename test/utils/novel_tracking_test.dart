import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/track.dart';
import 'package:mangayomi/utils/novel_tracking.dart';

void main() {
  test('novels use reading endpoints rather than anime/watch endpoints', () {
    expect(isReadingTrackerItemType(ItemType.novel), isTrue);
    expect(isReadingTrackerItemType(ItemType.manga), isTrue);
    expect(isReadingTrackerItemType(ItemType.anime), isFalse);
    expect(isReadingTrackerItemType(null), isFalse);
  });

  test('only novel-capable tracker services are active', () {
    for (final service in [
      TrackerProviders.myAnimeList,
      TrackerProviders.anilist,
      TrackerProviders.kitsu,
    ]) {
      expect(isSupportedNovelTracker(service.syncId), isTrue);
    }
    expect(isSupportedNovelTracker(TrackerProviders.simkl.syncId), isFalse);
    expect(isSupportedNovelTracker(TrackerProviders.trakt.syncId), isFalse);
    expect(isSupportedNovelTracker(null), isFalse);
  });
}
