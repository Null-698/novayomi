import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:shiori/shiori.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/l10n/generated/app_localizations.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/modules/library/providers/file_scanner.dart';
import 'package:mangayomi/models/settings.dart';
import 'package:mangayomi/modules/more/settings/browse/providers/browse_state_provider.dart';
import 'package:mangayomi/providers/reader_state_provider.dart';
import 'package:mangayomi/modules/onboarding/onboarding_screen.dart';
import 'package:mangayomi/modules/main_view/nav_groups.dart';
import 'package:mangayomi/providers/l10n_providers.dart';
import 'package:mangayomi/modules/widgets/tv_pill.dart';
import 'package:mangayomi/utils/platform_utils.dart';

const _goodUrl = 'https://example.invalid/index.json';

void main() {
  setUp(() => _StubHideItems.lastSet = null);
  tearDown(() => debugIsTvOverride = null);

  Future<void> pump(
    WidgetTester tester, {
    Brightness? brightness,
    bool disableAnimations = false,
    double textScale = 1,
    // The flow opens on language; most tests start on the novel source step.
    bool pastLanguage = true,
  }) async {
    // Tall viewport lets the repository form remain visible during tests.
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // The screen only reads the repo list to append to it, and writing
          // goes through Isar, which is not open in a test.
          for (final type in ItemType.values)
            extensionsRepoStateProvider(type)
                .overrideWith(() => _StubRepoState()),
          // Read and written as the steps advance, and both go through Isar,
          // which is not open in a test.
          // A repository that resolves, so the steps after adding one can be
          // reached without a network.
          getRepoInfosProvider(jsonUrl: _goodUrl).overrideWith(
            (ref) async => Repo(name: 'Test repo', jsonUrl: _goodUrl),
          ),
          // Reads Isar, which is not open in a test.
          localFoldersStateProvider.overrideWith(_StubLocalFolders.new),
          hideItemsStateProvider.overrideWith(_StubHideItems.new),
          mergeLibraryNavMobileStateProvider.overrideWith(_StubMergeNav.new),
          l10nLocaleStateProvider.overrideWith(_StubLocale.new),
          navGroupingProvider.overrideWith(_StubNavGrouping.new),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(brightness: brightness ?? Brightness.dark),
          // Mounted from builder, not home, because that is how main.dart
          // mounts it: outside the Navigator, with no Overlay above it.
          home: const SizedBox.shrink(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: disableAnimations,
              textScaler: TextScaler.linear(textScale),
            ),
            child: const OnboardingScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (pastLanguage) {
      await tester.tap(find.widgetWithText(ShioriButton, 'Next'));
      await tester.pumpAndSettle();
    }
  }

  ShioriButton addButton(WidgetTester tester) => tester.widget<ShioriButton>(
    find.widgetWithText(ShioriButton, 'Add repository'),
  );

  testWidgets('language is the first step', (tester) async {
    await pump(tester, pastLanguage: false);
    expect(find.text('Choose your language'), findsOneWidget);
    expect(find.text('Français'), findsOneWidget);
    expect(find.text('Deutsch'), findsOneWidget);
    expect(find.widgetWithText(ShioriButton, 'Restore a backup'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('language choice updates the selected row', (tester) async {
    await pump(tester, pastLanguage: false);
    await tester.tap(find.text('Français'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.widgetWithText(ListTile, 'Français'),
        matching: find.byIcon(Symbols.check_rounded),
      ),
      findsOneWidget,
    );
  });

  testWidgets('goes directly from language to novel repositories', (tester) async {
    await pump(tester);
    expect(find.text('Add a source'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.widgetWithText(FilterChip, 'Manga'), findsNothing);
    expect(find.widgetWithText(FilterChip, 'Anime'), findsNothing);
    expect(find.widgetWithText(FilterChip, 'Novel'), findsNothing);
    expect(_StubHideItems.lastSet, contains('/MangaLibrary'));
    expect(_StubHideItems.lastSet, contains('/AnimeLibrary'));
    expect(_StubHideItems.lastSet, isNot(contains('/NovelLibrary')));
  });

  testWidgets('can skip adding a repository', (tester) async {
    await pump(tester);
    expect(find.widgetWithText(ShioriButton, 'Skip for now'), findsOneWidget);
  });

  testWidgets('empty repository URL cannot be submitted', (tester) async {
    await pump(tester);
    expect(addButton(tester).onPressed, isNull);
  });

  testWidgets('invalid repository URL cannot be submitted', (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField), 'not a url');
    await tester.pump();
    expect(addButton(tester).onPressed, isNull);
  });

  testWidgets('absolute novel repository URL is accepted', (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField), _goodUrl);
    await tester.pump();
    expect(addButton(tester).onPressed, isNotNull);
  });

  testWidgets('can add a novel repository', (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField), _goodUrl);
    await tester.pump();
    await tester.tap(find.widgetWithText(ShioriButton, 'Add repository'));
    await tester.pumpAndSettle();
    expect(find.text('Test repo'), findsWidgets);
    expect(find.widgetWithText(ShioriButton, 'Continue'), findsOneWidget);
  });

  testWidgets('local novel files can be added from the repository step',
      (tester) async {
    await pump(tester);
    expect(find.widgetWithText(ShioriButton, 'Add a folder'), findsOneWidget);
    expect(find.text('Or use files you already have'), findsOneWidget);
  });

  testWidgets('backup restore is offered before the repository step only',
      (tester) async {
    await pump(tester, pastLanguage: false);
    expect(find.widgetWithText(ShioriButton, 'Restore a backup'), findsOneWidget);
    await tester.tap(find.widgetWithText(ShioriButton, 'Next'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ShioriButton, 'Restore a backup'), findsNothing);
  });

  testWidgets('back goes from repository to language', (tester) async {
    await pump(tester);
    await tester.tap(
      find.widgetWithIcon(IconButton, Symbols.arrow_back_rounded),
    );
    await tester.pumpAndSettle();
    expect(find.text('Choose your language'), findsOneWidget);
  });

  testWidgets('the first step has no back arrow', (tester) async {
    await pump(tester, pastLanguage: false);
    expect(find.widgetWithIcon(IconButton, Symbols.arrow_back_rounded),
        findsNothing);
  });

  testWidgets('two progress dots track language and source', (tester) async {
    Iterable<double> widths() => tester
        .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
        .map((c) => c.constraints?.maxWidth ?? 0);
    await pump(tester, pastLanguage: false);
    expect(widths().length, 2);
    expect(widths().first, greaterThan(widths().last));
    await tester.tap(find.widgetWithText(ShioriButton, 'Next'));
    await tester.pumpAndSettle();
    final current = widths().toList();
    expect(current[1], greaterThan(current[0]));
  });

  testWidgets('the novel source screen fits large text', (tester) async {
    await pump(tester, textScale: 2);
    expect(tester.takeException(), isNull);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('the language step fits large text', (tester) async {
    await pump(tester, textScale: 2, pastLanguage: false);
    expect(tester.takeException(), isNull);
    expect(find.widgetWithText(ShioriButton, 'Next'), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    testWidgets('the app logo is legible on $brightness', (tester) async {
      await pump(tester, brightness: brightness);
      final image = tester.widget<Image>(find.byType(Image).first);
      expect((image.image as AssetImage).assetName, 'assets/app_icons/icon.png');
      expect(image.color,
          brightness == Brightness.dark ? Colors.white : Colors.black);
    });
  }

  testWidgets('the back arrow tooltip opens without an overlay exception',
      (tester) async {
    await pump(tester);
    final back = find.widgetWithIcon(IconButton, Symbols.arrow_back_rounded);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: tester.getCenter(back));
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(back));
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV still offers only novel repositories', (tester) async {
    debugIsTvOverride = true;
    await pump(tester);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byType(TvPill), findsNothing);
    expect(find.byType(FilterChip), findsNothing);
    expect(_StubHideItems.lastSet, contains('/MangaLibrary'));
    expect(_StubHideItems.lastSet, contains('/AnimeLibrary'));
    expect(_StubHideItems.lastSet, isNot(contains('/NovelLibrary')));
    expect(tester.widget<TextField>(find.byType(TextField)).autofocus, isTrue);
  });
}

class _StubRepoState extends ExtensionsRepoState {
  @override
  List<Repo> build(ItemType itemType) => const [];

  // Without this the real one writes to Isar, throws, and the screen reports
  // the add as failed.
  @override
  Future<void> set(List<Repo> value) async => state = value;
}

class _StubLocalFolders extends LocalFoldersState {
  @override
  List<LocalFolder> build() => const [];

  @override
  void set(List<LocalFolder> value) => state = value;
}

class _StubHideItems extends HideItemsState {
  /// What the screen last wrote. Captured because the provider is autoDispose:
  /// reading it back after nothing is listening rebuilds it and the write is
  /// gone, which made an earlier version of this test look like a failure.
  static List<String>? lastSet;

  @override
  List<String> build() => const ['/trackerLibrary'];

  @override
  void set(List<String> values) {
    lastSet = values;
    state = values;
  }
}

class _StubMergeNav extends MergeLibraryNavMobileState {
  @override
  bool build() => false;

  @override
  void set(bool value) => state = value;
}

class _StubLocale extends L10nLocaleState {
  @override
  Locale build() => const Locale('en');

  @override
  void setLocale(Locale locale) => state = locale;

  @override
  void adoptDeviceLocaleIfUnset() {}
}

class _StubNavGrouping extends NavGroupingState {
  @override
  bool build() => true;

  @override
  void set(bool value) => state = value;
}
