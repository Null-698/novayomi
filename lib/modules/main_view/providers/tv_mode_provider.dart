import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangayomi/repositories/settings_repository.dart';
import 'package:mangayomi/utils/platform_utils.dart';

// Android TV preferences, stored on the Settings collection. A null field means
// "auto" (follow the default below); a stored bool is an explicit override.

/// Whether to show the anime-only TV layout (manga + novel libraries hidden,
/// anime-first). Defaults to [isTv] - i.e. on for Android TV, off everywhere
/// else - and can be explicitly overridden by the user as an escape hatch, so
/// a wrong detection can never strand someone with manga hidden.
final animeOnlyTvModeProvider = NotifierProvider<AnimeOnlyTvMode, bool>(
  AnimeOnlyTvMode.new,
);

class AnimeOnlyTvMode extends Notifier<bool> {
  @override
  bool build() => settingsRepository.current.tvAnimeOnlyOverride ?? isTv;

  /// Explicitly turns the anime-only layout on/off and persists the choice.
  void set(bool value) {
    state = value;
    settingsRepository.update((s) => s.tvAnimeOnlyOverride = value);
  }
}

