import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/settings.dart';
import 'package:mangayomi/services/anilist_discovery.dart';
import 'package:mangayomi/services/discovery/media_lookup_context.dart';
import 'package:mangayomi/services/recommendation.dart';

void main() {
  test('recommendation results preserve novel search targets and scores', () {
    final rated = RecommendationResult.fromDiscovery(
      DiscoveryMedia(
        id: 81,
        english: 'A Light Novel',
        averageScore: 84,
        type: 'MANGA',
        format: 'NOVEL',
      ),
      itemType: ItemType.novel,
    );
    final unrated = RecommendationResult.fromDiscovery(
      DiscoveryMedia(id: 82, english: 'Another Novel', type: 'MANGA'),
      itemType: ItemType.novel,
    );
    expect(rated.rating?.valueLabel, '84%');
    expect(unrated.rating, isNull);
    expect(rated.searchTarget.itemType, ItemType.novel);
    expect(rated.title, 'A Light Novel');
    expect(rated.provider, RecommendationProvider.anilist);
  });

  test('video entries do not trigger obsolete recommendation services', () async {
    final result = await getRecommendations(
      const MediaLookupContext(title: 'A TV show', itemType: ItemType.anime),
      AlgorithmWeights(),
    );
    expect(result, isEmpty);
  });
}
