import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/track.dart';

/// Media names in this public API remain stable for extension/UI compatibility.
enum MediaKind { unknown, anime }

/// Snapshot of novel metadata for asynchronous recommendation searches.
/// Does not retain any Isar object across an asynchronous request.
final class MediaLookupContext {
  const MediaLookupContext({
    required this.title,
    required this.itemType,
    this.sourceLink,
    this.sourceName,
    this.year,
    this.kind = MediaKind.unknown,
    this.anilistId,
  });

  factory MediaLookupContext.fromManga(
    Manga manga, {
    Track? track,
    Iterable<Track> tracks = const [],
    int? year,
    MediaKind? kind,
    String? chapterName,
  }) {
    final relevantTracks = <Track>[?track, ...tracks];
    Track? aniListTrack;
    for (final candidate in relevantTracks) {
      if (candidate.syncId == 2 ||
          Uri.tryParse(candidate.trackingUrl ?? '')?.host.toLowerCase() ==
              'anilist.co') {
        aniListTrack = candidate;
        break;
      }
    }
    final rawTitle = _nonEmpty(manga.name) ??
        _nonEmpty(relevantTracks.firstOrNull?.title) ?? '';
    final titleAndYear = _titleAndYear(rawTitle);
    return MediaLookupContext(
      title: titleAndYear.title,
      itemType: manga.itemType,
      sourceLink: _nonEmpty(manga.link),
      sourceName: _nonEmpty(manga.source),
      year: year ?? titleAndYear.year,
      kind: kind ??
          (manga.itemType == ItemType.anime
              ? MediaKind.anime
              : MediaKind.unknown),
      anilistId: aniListTrack?.mediaId,
    );
  }

  final String title;
  final ItemType itemType;
  final String? sourceLink;
  final String? sourceName;
  final int? year;
  final MediaKind kind;
  final int? anilistId;
}

({String title, int? year}) _titleAndYear(String rawTitle) {
  final match = RegExp(r'^(.*?\S)\s*[\(\[]((?:18|19|20)\d{2})[\)\]]$')
      .firstMatch(rawTitle);
  if (match == null) return (title: rawTitle, year: null);
  return (
    title: match.group(1)?.trim() ?? rawTitle,
    year: int.tryParse(match.group(2) ?? ''),
  );
}

String? _nonEmpty(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}
