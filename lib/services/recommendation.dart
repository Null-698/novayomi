import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/settings.dart';
import 'package:mangayomi/services/anilist_discovery.dart';
import 'package:mangayomi/services/discovery/media_lookup_context.dart';
import 'package:mangayomi/services/discovery/search_target.dart';
import 'package:mangayomi/utils/extensions/string_extensions.dart';

/// Novel recommendations from AniList. Keep the shared result representation
/// because the novel recommendation screen also uses its rating and search data.
///
/// Errors propagate to the screen so users can retry a failed request.
/// [algorithmWeights] is retained for existing settings/callers.
Future<List<RecommendationResult>> getRecommendations(
  MediaLookupContext media,
  AlgorithmWeights algorithmWeights,
) async {
  // All new UI paths are novel-only, and older non-novel records are ignored.
  if (media.itemType != ItemType.novel) return const [];

  final mediaId = media.anilistId ??
      await searchMediaId(ItemType.novel, media.title);
  if (mediaId == null) return const [];
  final recommendations = await fetchRecommendations(mediaId);
  return recommendations
      .map(
        (recommendation) => RecommendationResult.fromDiscovery(
          recommendation,
          itemType: ItemType.novel,
        ),
      )
      .toList(growable: false);
}

enum RecommendationProvider { anilist }

/// A catalog rating and its scale.
///
/// A catalog score is distinct from a similarity percentage.
class CatalogRating {
  const CatalogRating({
    required this.value,
    required this.maximum,
    required this.provider,
  });

  final double value;
  final double maximum;
  final RecommendationProvider provider;

  String get valueLabel {
    if (maximum == 10) return '${value.toStringAsFixed(1)}/10';
    if (maximum == 100) return '${value.round()}%';
    return '${value.toStringAsFixed(1)}/${maximum.toStringAsFixed(0)}';
  }
}

class RecommendationResult {
  const RecommendationResult({
    required this.id,
    required this.provider,
    required this.kind,
    required this.searchTarget,
    required this.imgURLs,
    required this.genres,
    this.anilistId,
    this.myanimelistId,
    this.year,
    this.rating,
    this.titleRomaji,
    this.titleEnglish,
    this.titleNative,
    this.description,
  });

  final String id;
  final RecommendationProvider provider;
  final MediaKind kind;
  final SearchTarget searchTarget;
  final int? anilistId;
  final int? myanimelistId;
  final int? year;
  final CatalogRating? rating;
  final String? titleRomaji;
  final String? titleEnglish;
  final String? titleNative;
  final String? description;
  final List<String> imgURLs;
  final List<String> genres;

  String get title =>
      titleEnglish ?? titleRomaji ?? titleNative ?? searchTarget.query;

  factory RecommendationResult.fromDiscovery(
    DiscoveryMedia media, {
    required ItemType itemType,
  }) => RecommendationResult(
    id: 'anilist:${media.id}',
    provider: RecommendationProvider.anilist,
    kind: media.isAnime ? MediaKind.anime : MediaKind.unknown,
    searchTarget: SearchTarget(query: media.title, itemType: itemType),
    anilistId: media.id,
    myanimelistId: media.idMal,
    year: media.seasonYear,
    rating: media.averageScore == null
        ? null
        : CatalogRating(
            value: media.averageScore!.toDouble(),
            maximum: 100,
            provider: RecommendationProvider.anilist,
          ),
    titleRomaji: media.romaji,
    titleEnglish: media.english,
    titleNative: media.native,
    description: media.description?.htmlToPlainText(),
    imgURLs: media.coverImage != null ? [media.coverImage!] : const [],
    genres: media.genres,
  );

}
