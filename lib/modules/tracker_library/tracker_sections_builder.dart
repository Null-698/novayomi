import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/track.dart';
import 'package:mangayomi/models/track_search.dart';
import 'package:mangayomi/modules/manga/detail/providers/track_state_providers.dart';
import 'package:mangayomi/modules/tracker_library/tracker_library_section.dart';

/// Build novel catalog sections. MAL, AniList and Kitsu use their manga
/// catalogs for light novels, but the local item type remains Novel.
List<TrackLibrarySection> buildTrackerSections({
  required WidgetRef ref,
  required TrackerProviders trackerProvider,
  required ItemType itemType,
  String? searchQuery,
}) {
  // The tracker library is deliberately novel-only.
  if (itemType != ItemType.novel) return <TrackLibrarySection>[];
  final syncId = trackerProvider.syncId;
  final sections = switch (syncId) {
    1 => _sectionsMAL(ref, syncId),
    2 => _sectionsAL(ref, syncId),
    3 => _sectionsKitsu(ref, syncId),
    _ => <TrackLibrarySection>[],
  };

  if (searchQuery != null && searchQuery.isNotEmpty && sections.isNotEmpty) {
    sections.insert(0, TrackLibrarySection(
      name: 'Search results',
      syncId: syncId,
      func: _fetchSearch(ref, syncId, searchQuery, ItemType.novel),
      itemType: ItemType.novel,
      isSearch: true,
    ));
  }

  return sections;
}

TrackLibrarySection _bookSection(
  int syncId,
  String name,
  Future<List<TrackSearch>?> Function() function,
) => TrackLibrarySection(
  name: name,
  syncId: syncId,
  itemType: ItemType.novel,
  func: function,
);

List<TrackLibrarySection> _sectionsMAL(WidgetRef ref, int id) => [
  _bookSection(id, 'Continue reading', _fetchUserData(ref, id)),
  _bookSection(id, 'Popular titles',
      _fetchGeneralData(ref, id, rankingType: 'bypopularity')),
  _bookSection(id, 'Top reading titles',
      _fetchGeneralData(ref, id, rankingType: 'manga')),
];

List<TrackLibrarySection> _sectionsKitsu(WidgetRef ref, int id) => [
  _bookSection(id, 'Continue reading', _fetchUserData(ref, id)),
  _bookSection(id, 'Popular titles', _fetchGeneralData(ref, id)),
  _bookSection(id, 'Recently updated',
      _fetchGeneralData(ref, id, rankingType: '-updatedAt')),
  _bookSection(id, 'Best rated',
      _fetchGeneralData(ref, id, rankingType: '-averageRating')),
];

List<TrackLibrarySection> _sectionsAL(WidgetRef ref, int id) => [
  _bookSection(id, 'Continue reading', _fetchUserData(ref, id)),
  _bookSection(id, 'Plan to read', _fetchPlanningData(ref, id)),
  _bookSection(id, 'Popular titles',
      _fetchGeneralData(ref, id, rankingType: 'sort: POPULARITY_DESC')),
  _bookSection(id, 'Trending titles',
      _fetchGeneralData(ref, id, rankingType: 'sort: TRENDING_DESC')),
  _bookSection(id, 'Recently updated',
      _fetchGeneralData(ref, id,
          rankingType: 'sort: [UPDATED_AT_DESC, POPULARITY_DESC], status: RELEASING')),
];

Track _lookupTrack(int id) => Track(syncId: id, status: TrackStatus.completed);

Future<List<TrackSearch>?> Function() _fetchSearch(
  WidgetRef ref, int id, String query, ItemType type,
) => () async => ref.read(trackStateProvider(
  track: _lookupTrack(id), itemType: type, widgetRef: ref,
).notifier).search(query);

Future<List<TrackSearch>?> Function() _fetchGeneralData(
  WidgetRef ref, int id, {String? rankingType}
) => () async => ref.read(trackStateProvider(
  track: _lookupTrack(id), itemType: ItemType.novel, widgetRef: ref,
).notifier).fetchGeneralData(rankingType: rankingType);

Future<List<TrackSearch>?> Function() _fetchUserData(
  WidgetRef ref, int id,
) => () async => ref.read(trackStateProvider(
  track: _lookupTrack(id), itemType: ItemType.novel, widgetRef: ref,
).notifier).fetchUserData();

Future<List<TrackSearch>?> Function() _fetchPlanningData(
  WidgetRef ref, int id,
) => () async => ref.read(trackStateProvider(
  track: _lookupTrack(id), itemType: ItemType.novel, widgetRef: ref,
).notifier).fetchPlanningData();
