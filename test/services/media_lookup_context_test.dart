import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/track.dart';
import 'package:mangayomi/services/discovery/media_lookup_context.dart';

Manga _novel(String title) => Manga(
  name: title,
  source: 'Novel source',
  link: '/books/novel',
  author: null,
  artist: null,
  genre: const [],
  imageUrl: null,
  lang: 'en',
  status: Status.unknown,
  description: null,
  sourceId: 1,
  itemType: ItemType.novel,
);

void main() {
  test('novel lookup uses novel catalog identity and stable title', () {
    final manga = _novel('Novel Title (2024)');
    final track = Track(
      mediaId: 42,
      syncId: 2,
      title: 'Novel Title',
      trackingUrl: 'https://anilist.co/manga/42/Novel-Title',
      status: TrackStatus.reading,
      itemType: ItemType.novel,
    );
    final context = MediaLookupContext.fromManga(manga, track: track);
    manga.name = 'Updated after lookup';
    track.mediaId = 100;
    expect(context.title, 'Novel Title');
    expect(context.year, 2024);
    expect(context.itemType, ItemType.novel);
    expect(context.kind, MediaKind.unknown);
    expect(context.anilistId, 42);
    expect(context.sourceLink, '/books/novel');
  });

  test('legacy TV tracker identities are not used for novel lookup', () {
    final track = Track(
      mediaId: 99,
      syncId: 5,
      trackingUrl: 'https://trakt.tv/shows/example',
      status: TrackStatus.watching,
      itemType: ItemType.anime,
    );
    final lookup = MediaLookupContext.fromManga(_novel('A Novel'), track: track);
    expect(lookup.anilistId, isNull);
    expect(lookup.title, 'A Novel');
  });
}
