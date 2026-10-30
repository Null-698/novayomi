import 'dart:async';
import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:mangayomi/modules/more/settings/security/providers/security_state_provider.dart';
import 'package:mangayomi/services/secure_screen.dart';
import 'package:mangayomi/utils/app_lock.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangayomi/l10n/generated/app_localizations.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/settings.dart';
import 'package:mangayomi/providers/reader_state_provider.dart';
import 'package:mangayomi/modules/novel/tts/novel_tts_service.dart';
import 'package:mangayomi/modules/novel/utils/novel_reader_fonts.dart';
import 'package:mangayomi/modules/more/settings/appearance/providers/app_ui_scale_state_provider.dart';
import 'package:mangayomi/modules/more/settings/appearance/providers/date_format_state_provider.dart';
import 'package:mangayomi/modules/more/settings/appearance/providers/floating_navigation_bar_state_provider.dart';
import 'package:mangayomi/modules/more/settings/appearance/providers/pure_black_dark_mode_state_provider.dart';
import 'package:mangayomi/modules/more/settings/appearance/providers/theme_mode_state_provider.dart';
import 'package:mangayomi/modules/more/settings/appearance/providers/tint_surfaces_state_provider.dart';
import 'package:mangayomi/modules/more/settings/downloads/providers/downloads_state_provider.dart';
import 'package:mangayomi/modules/more/settings/general/providers/general_state_provider.dart';
import 'package:mangayomi/modules/more/settings/general/providers/doh_provider_notifier.dart';
import 'package:mangayomi/services/http/doh/doh_providers.dart';
import 'package:mangayomi/services/http/doh/doh_custom_store.dart';
import 'package:mangayomi/services/http/cf_proxy_store.dart';
import 'package:mangayomi/modules/more/settings/browse/providers/browse_state_provider.dart';
import 'package:mangayomi/providers/l10n_providers.dart';
import 'package:mangayomi/repositories/source_repository.dart';
import 'package:mangayomi/utils/date.dart';

/// UIKit settings, with Riverpod as the sole persistent settings backend.
class NativeIosPreferencesScreen extends ConsumerStatefulWidget {
  final String section;
  const NativeIosPreferencesScreen({super.key, required this.section});
  @override
  ConsumerState<NativeIosPreferencesScreen> createState() => _NativeIosPreferencesState();
}

class _NativeIosPreferencesState extends ConsumerState<NativeIosPreferencesScreen> {
  final LocalAuthentication _auth = LocalAuthentication();
  bool _canAuthenticate = false;
  @override
  void initState() {
    super.initState();
    if (widget.section == 'security') {
      Future<void>(() async {
        try {
          final result = await _auth.canCheckBiometrics ||
              await _auth.isDeviceSupported();
          if (mounted) setState(() => _canAuthenticate = result);
        } catch (_) {
          if (mounted) setState(() => _canAuthenticate = false);
        }
      });
    }
  }
  Future<bool> _authenticate() async {
    try {
      return await _auth.authenticate(
        localizedReason: 'Authenticate to change security settings',
        biometricOnly: false,
        persistAcrossBackgrounding: true,
      );
    } catch (_) { return false; }
  }
  MethodChannel? _channel;
  Map<String, Object?> _snapshot = const {};
  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }
  void _created(int id) {
    _channel = MethodChannel('novayomi/native-preferences/$id');
    _channel?.setMethodCallHandler(_onNative);
    unawaited(_channel!.invokeMethod<void>('update', _snapshot));
  }
  Future<void> _onNative(MethodCall call) async {
    if (!mounted) return;
    try {
      switch (call.method) {
        case 'close':
          if (context.canPop()) context.pop();
        case 'navigate':
          final path = call.arguments as String?;
          if (path == null) return;
          if (path == '/SourceRepositories' || path == '/sourceFilter') {
            context.push(path, extra: ItemType.novel);
          } else {
            context.push(path);
          }
        case 'action':
          if (call.arguments == 'clearSources') await sourceRepository.clearAll();
        case 'change':
          final data = call.arguments;
          if (data is! Map) return;
          final id = data['id'] as String?;
          if (id == null) return;
          if ((id == 'appLock' || id == 'appLockDelay') &&
              (!_canAuthenticate || !await _authenticate())) {
            await _channel?.invokeMethod<void>('update', _snapshot);
            return;
          }
          _write(id, data['value']);
          if (mounted) setState(() {});
      }
    } catch (error, stack) {
      debugPrint('Native preference: $error');
      debugPrintStack(stackTrace: stack);
      if (mounted) await _channel?.invokeMethod<void>('error', error.toString());
    }
  }
  void _write(String id, Object? value) {
    final enabled = value == true;
    final amount = value is num ? value.toDouble() : 0.0;
    switch (id) {
      case 'novelTheme':
        final scheme = switch (value) {
          'light' => ('#FFFFFF', '#000000'),
          'black' => ('#000000', '#FFFFFF'),
          'sepia' => ('#F5E6D3', '#5F4B32'),
          _ => ('#292832', '#CCCCCC'),
        };
        ref.read(novelReaderThemeStateProvider.notifier).set(scheme.$1);
        ref.read(novelReaderTextColorStateProvider.notifier).set(scheme.$2);
      case 'novelBackground':
        final bg = value?.toString() ?? '';
        if (bg.length == 7 && bg.startsWith('#') &&
            int.tryParse(bg.substring(1), radix: 16) != null) {
          ref.read(novelReaderThemeStateProvider.notifier).set(bg);
        }
      case 'novelForeground':
        final fg = value?.toString() ?? '';
        if (fg.length == 7 && fg.startsWith('#') &&
            int.tryParse(fg.substring(1), radix: 16) != null) {
          ref.read(novelReaderTextColorStateProvider.notifier).set(fg);
        }
      case 'novelFontSize':
        ref.read(novelFontSizeStateProvider.notifier).set(amount.round());
      case 'novelPadding':
        ref.read(novelReaderPaddingStateProvider.notifier).set(amount.round());
      case 'novelLineHeight':
        ref.read(novelReaderLineHeightStateProvider.notifier).set(amount);
      case 'novelFontFamily':
        ref.read(novelFontFamilyStateProvider.notifier)
            .set(value == 'default' ? null : value?.toString());
      case 'novelAlign':
        final matches = NovelTextAlign.values.where((a) => a.name == value).toList();
        if (matches.isNotEmpty) {
          ref.read(novelTextAlignStateProvider.notifier).set(matches.first);
        }
      case 'novelMode':
        final matches = ReaderMode.values.where((a) => a.name == value).toList();
        if (matches.isNotEmpty) {
          ref.read(defaultReadingModeStateProvider.notifier).set(matches.first);
        }
      case 'keepScreen':
        ref.read(keepScreenOnReaderStateProvider.notifier).set(enabled);
      case 'scrollPercentage':
        ref.read(novelShowScrollPercentageStateProvider.notifier).set(enabled);
      case 'removeSpacing':
        ref.read(novelRemoveExtraParagraphSpacingStateProvider.notifier).set(enabled);
      case 'tapScroll':
        ref.read(novelTapToScrollStateProvider.notifier).set(enabled);
      case 'volumePaging':
        ref.read(volumeKeysPagingStateProvider.notifier).set(enabled);
      case 'volumeInvert':
        ref.read(volumeKeysInvertedStateProvider.notifier).set(enabled);
      case 'ttsRate':
        ref.read(ttsSpeechRateStateProvider.notifier).set(amount);
        NovelTtsService.instance.setSpeed(amount);
      case 'ttsPitch':
        ref.read(ttsPitchStateProvider.notifier).set(amount);
        NovelTtsService.instance.setPitch(amount);
      case 'ttsLanguage':
        final lang = value?.toString().trim() ?? '';
        ref.read(ttsLanguageStateProvider.notifier).set(lang.isEmpty ? null : lang);
        if (lang.isNotEmpty) NovelTtsService.instance.setLanguage(lang);
      case 'dohEnabled':
        ref.read(doHProviderStateProvider.notifier).setDoHEnabled(enabled);
      case 'dohProvider':
        final providerId = int.tryParse(value.toString());
        if (providerId == DoHProviders.customId) {
          ref.read(doHProviderStateProvider.notifier).setCustomDoH(DohCustomStore.url);
        } else if (providerId != null && DoHProviders.byId.containsKey(providerId)) {
          ref.read(doHProviderStateProvider.notifier).setDoHProvider(providerId);
        }
      case 'dohUrl':
        final url = value?.toString().trim() ?? '';
        if (url.startsWith('https://')) {
          ref.read(doHProviderStateProvider.notifier).setCustomDoH(url);
        } else {
          throw const FormatException('Custom DNS over HTTPS must start with https://');
        }
      case 'cfProxy':
        final url = value?.toString().trim() ?? '';
        if (url.isEmpty || url.startsWith('http://') || url.startsWith('https://')) {
          CfProxyStore.setUrl(url);
        } else {
          throw const FormatException('Proxy URL must begin with http:// or https://');
        }
      case 'appLock':
        ref.read(appLockEnabledStateProvider.notifier).set(enabled);
        if (!enabled) ref.read(appUnlockedStateProvider.notifier).unlock();
      case 'appLockDelay':
        final minutes = int.tryParse(value.toString());
        if (minutes != null && appLockDelays.contains(minutes)) {
          ref.read(appLockDelayStateProvider.notifier).set(minutes);
        }
      case 'secureScreen':
        final modes = SecureScreenMode.values.where((v) => v.name == value).toList();
        if (modes.isNotEmpty) ref.read(secureScreenStateProvider.notifier).set(modes.first);
      case 'theme':
        if (value == 'system') {
          ref.read(followSystemThemeStateProvider.notifier).set(true);
        } else {
          ref.read(followSystemThemeStateProvider.notifier).set(false);
          if (value == 'dark') ref.read(themeModeStateProvider.notifier).setDarkTheme();
          if (value == 'light') ref.read(themeModeStateProvider.notifier).setLightTheme();
        }
      case 'pureBlack':
        ref.read(pureBlackDarkModeStateProvider.notifier).set(enabled);
      case 'tintSurfaces':
        ref.read(tintSurfacesStateProvider.notifier).set(enabled);
      case 'uiScale':
        ref.read(appUiScaleStateProvider.notifier).set(amount, end: true);
      case 'floatingNav':
        ref.read(floatingNavigationBarStateProvider.notifier).set(enabled);
      case 'locale':
        final matches = AppLocalizations.supportedLocales
            .where((e) => e.toLanguageTag() == value).toList();
        if (matches.isNotEmpty) {
          ref.read(l10nLocaleStateProvider.notifier).setLocale(matches.first);
        }
      case 'relativeTimestamps':
        ref.read(relativeTimesTampsStateProvider.notifier)
            .set(int.tryParse(value.toString()) ?? 0);
      case 'dateFormat':
        if (dateFormatsList.contains(value)) {
          ref.read(dateFormatStateProvider.notifier).set(value as String);
        }
      case 'showNsfw':
        ref.read(showNSFWStateProvider.notifier).set(enabled);
      case 'onlyPinned':
        ref.read(onlyIncludePinnedSourceStateProvider.notifier).set(enabled);
      case 'extensionsCheck':
        ref.read(checkForExtensionsUpdateStateProvider.notifier).set(enabled);
      case 'extensionsAuto':
        ref.read(autoUpdateExtensionsStateProvider.notifier).set(enabled);
      case 'developerMode':
        ref.read(developerModeStateProvider.notifier).set(enabled);
      case 'wifiOnly':
        ref.read(onlyOnWifiStateProvider.notifier).set(enabled);
      case 'cbz':
        ref.read(saveAsCBZArchiveStateProvider.notifier).set(enabled);
      case 'deleteAfterReading':
        ref.read(deleteDownloadAfterReadingStateProvider.notifier).set(enabled);
      case 'allowConcurrent':
        ref.read(allowConcurrentDownloadsStateProvider.notifier).set(enabled);
      case 'askDestination':
        ref.read(askDownloadDestinationStateProvider.notifier).set(enabled);
      case 'downloadNew':
        ref.read(downloadNewChaptersStateProvider.notifier).set(enabled);
      case 'deleteBookmarked':
        ref.read(deleteBookmarkedAfterReadingStateProvider.notifier).set(enabled);
      case 'concurrent':
        ref.read(concurrentDownloadsStateProvider.notifier).set(amount.round());
      case 'delay':
        ref.read(downloadDelaySecondsStateProvider.notifier).set(amount.round());
      case 'downloadAhead':
        ref.read(downloadAheadWhileReadingStateProvider.notifier).set(amount.round());
      case 'deleteSlot':
        ref.read(deleteAfterReadingSlotStateProvider.notifier).set(amount.round());
      case 'updateWifi':
        ref.read(autoLibraryUpdateWifiOnlyStateProvider.notifier).set(enabled);
      case 'updateInterval':
        ref.read(autoLibraryUpdateIntervalStateProvider.notifier).set(amount.round());
      case 'skipComplete':
        ref.read(libraryUpdateSkipCompletedStateProvider.notifier).set(enabled);
      case 'skipUnread':
        ref.read(libraryUpdateSkipUnreadStateProvider.notifier).set(enabled);
      case 'skipNotStarted':
        ref.read(libraryUpdateSkipNotStartedStateProvider.notifier).set(enabled);
      case 'navTooltips':
        ref.read(showNavDoubleTapTooltipStateProvider.notifier).set(enabled);
      case 'userAgent':
        ref.read(userAgentStateProvider.notifier).set(value?.toString() ?? '');
      case 'customDns':
        ref.read(customDnsStateProvider.notifier).set(value?.toString() ?? '');
    }
  }
  Map<String, Object?> item(String id, String title, Object? value, {
    String type = 'toggle', String? detail, String? symbol,
    num? min, num? max, num? step, String? display,
    List<Map<String, Object?>>? choices, bool destructive = false,
  }) => {
    'id': id, 'title': title, 'type': type,
    if (value != null) 'value': value,
    if (detail != null) 'detail': detail,
    if (symbol != null) 'symbol': symbol,
    if (min != null) 'min': min,
    if (max != null) 'max': max,
    if (step != null) 'step': step,
    if (display != null) 'display': display,
    if (choices != null) 'choices': choices,
    if (destructive) 'destructive': true,
  };
  Map<String, Object?> group(String title, List<Map<String, Object?>> rows,
      {String? footer}) => {'title': title, 'rows': rows, if (footer != null) 'footer': footer};
  Map<String, Object?> choice(String id, String name) => {'value': id, 'title': name};

  @override
  Widget build(BuildContext context) {
    final groups = <Map<String, Object?>>[];
    String title;
    switch (widget.section) {
      case 'security':
        title = 'Security';
        final locked = ref.watch(appLockEnabledStateProvider);
        groups.add(group('App lock', [
          item('appLock', 'Require device authentication', locked,
            detail: _canAuthenticate ? 'Authenticate to modify' : 'Device authentication unavailable'),
          if (locked) item('appLockDelay', 'App lock delay',
            ref.watch(appLockDelayStateProvider).toString(),
            type: 'choice', display: ref.watch(appLockDelayStateProvider).toString(),
            choices: [for (final minutes in appLockDelays)
              choice(minutes.toString(), minutes == appLockOnLaunchOnly
                ? 'On launch' : minutes == 0 ? 'Immediately' : minutes.toString() + ' minutes')]),
        ], footer: 'Changing the app lock requires device authentication.'));
        groups.add(group('Screen privacy', [
          item('secureScreen', 'Secure screen',
            ref.watch(secureScreenStateProvider).name,
            type: 'choice',
            display: ref.watch(secureScreenStateProvider).name,
            choices: [for (final mode in SecureScreenMode.values)
              choice(mode.name, mode.name)]),
        ]));
      case 'appearance':
        title = 'Appearance';
        final follow = ref.watch(followSystemThemeStateProvider);
        final dark = ref.watch(themeModeStateProvider);
        final theme = follow ? 'system' : dark ? 'dark' : 'light';
        groups.add(group('Theme', [
          item('theme', 'Color scheme', theme, type: 'choice', display: theme,
            choices: [choice('system', 'System'), choice('light', 'Light'), choice('dark', 'Dark')]),
          if (dark) item('pureBlack', 'Pure black dark mode',
            ref.watch(pureBlackDarkModeStateProvider)),
          item('tintSurfaces', 'Tint surfaces with palette', ref.watch(tintSurfacesStateProvider)),
        ]));
        groups.add(group('Interface', [
          item('uiScale', 'UI scale', ref.watch(appUiScaleStateProvider),
            type: 'slider', min: 0.85, max: 1.25, step: 0.05),
          item('locale', 'App language', ref.watch(l10nLocaleStateProvider).toLanguageTag(),
            type: 'choice', display: ref.watch(l10nLocaleStateProvider).toLanguageTag(),
            choices: [for (final locale in AppLocalizations.supportedLocales)
              choice(locale.toLanguageTag(), locale.toLanguageTag())]),
          item('floatingNav', 'Floating navigation bar', ref.watch(floatingNavigationBarStateProvider)),
          item('/customNavigationSettings', 'Reorder navigation', null,
            type: 'link', symbol: 'list.number'),
        ]));
        final relative = ref.watch(relativeTimesTampsStateProvider);
        groups.add(group('Date & Time', [
          item('relativeTimestamps', 'Relative timestamps', relative.toString(),
            type: 'choice', display: relative.toString(),
            choices: [for (var i = 0; i < 3; i++) choice(i.toString(), i.toString())]),
          item('dateFormat', 'Date format', ref.watch(dateFormatStateProvider),
            type: 'choice', display: ref.watch(dateFormatStateProvider),
            choices: [for (final format in dateFormatsList) choice(format, format)]),
        ]));
      case 'browseS':
        title = 'Browse';
        final check = ref.watch(checkForExtensionsUpdateStateProvider);
        groups.add(group('Extensions', [
          item('/extensionServer', 'Extension server', null, type: 'link'),
          item('/SourceRepositories', 'Novel extension repositories', null, type: 'link'),
          item('extensionsCheck', 'Check for extension updates', check),
          if (check) item('extensionsAuto', 'Automatically update extensions',
            ref.watch(autoUpdateExtensionsStateProvider)),
          item('developerMode', 'Developer mode', ref.watch(developerModeStateProvider)),
        ]));
        groups.add(group('Global Search', [
          item('onlyPinned', 'Only include pinned sources',
            ref.watch(onlyIncludePinnedSourceStateProvider)),
        ]));
        groups.add(group('Content', [
          item('showNsfw', 'Show adult sources', ref.watch(showNSFWStateProvider)),
        ]));
        groups.add(group('Cleanup', [
          item('clearSources', 'Clear all sources', null, type: 'action',
            destructive: true, detail: 'Remove installed source information.'),
        ]));
      case 'downloads':
        title = 'Downloads';
        groups.add(group('Network and storage', [
          item('wifiOnly', 'Download on Wi-Fi only', ref.watch(onlyOnWifiStateProvider)),
          item('cbz', 'Save as CBZ', ref.watch(saveAsCBZArchiveStateProvider)),
          item('askDestination', 'Ask download destination', ref.watch(askDownloadDestinationStateProvider)),
          item('downloadNew', 'Automatically download new chapters', ref.watch(downloadNewChaptersStateProvider)),
          item('/downloadQueue', 'Download queue', null, type: 'link'),
        ]));
        groups.add(group('Concurrent downloads', [
          item('allowConcurrent', 'Allow concurrent downloads',
            ref.watch(allowConcurrentDownloadsStateProvider)),
          item('concurrent', 'Max concurrent', ref.watch(concurrentDownloadsStateProvider),
            type: 'slider', min: 1, max: 10, step: 1),
          item('delay', 'Delay (seconds)', ref.watch(downloadDelaySecondsStateProvider),
            type: 'slider', min: 0, max: 60, step: 1),
        ]));
        groups.add(group('Reading and cleanup', [
          item('downloadAhead', 'Download ahead while reading',
            ref.watch(downloadAheadWhileReadingStateProvider),
            type: 'slider', min: 0, max: 10, step: 1),
          item('deleteAfterReading', 'Delete downloads after reading',
            ref.watch(deleteDownloadAfterReadingStateProvider)),
          item('deleteSlot', 'Chapters to keep',
            ref.watch(deleteAfterReadingSlotStateProvider),
            type: 'slider', min: 0, max: 20, step: 1),
          item('deleteBookmarked', 'Delete bookmarked chapters after reading',
            ref.watch(deleteBookmarkedAfterReadingStateProvider)),
        ]));
      case 'general':
        title = 'General';
        groups.add(group('Library updates', [
          item('updateInterval', 'Update interval (hours)',
            ref.watch(autoLibraryUpdateIntervalStateProvider),
            type: 'slider', min: 0, max: 24, step: 1),
          item('updateWifi', 'Update on Wi-Fi only',
            ref.watch(autoLibraryUpdateWifiOnlyStateProvider)),
          item('skipComplete', 'Skip completed', ref.watch(libraryUpdateSkipCompletedStateProvider)),
          item('skipUnread', 'Skip with unread chapters', ref.watch(libraryUpdateSkipUnreadStateProvider)),
          item('skipNotStarted', 'Skip not started', ref.watch(libraryUpdateSkipNotStartedStateProvider)),
        ]));
        final doh = ref.watch(doHProviderStateProvider);
        final options = ref.watch(availableDoHProvidersProvider);
        groups.add(group('Network', [
          item('dohEnabled', 'DNS over HTTPS', doh.enabled),
          if (doh.enabled) ...[
            item('dohProvider', 'DNS provider',
              (doh.providerId ?? 0).toString(), type: 'choice',
              display: doh.providerId == DoHProviders.customId ? 'Custom' :
                (DoHProviders.byId[doh.providerId ?? 0]?.name ?? 'Cloudflare'),
              choices: [
                for (final provider in options)
                  choice(provider.id.toString(), provider.name),
                choice(DoHProviders.customId.toString(), 'Custom'),
              ]),
            if (doh.providerId == DoHProviders.customId)
              item('dohUrl', 'Custom HTTPS DNS endpoint', DohCustomStore.url,
                type: 'text'),
          ] else
            item('customDns', 'Custom DNS', ref.watch(customDnsStateProvider), type: 'text'),
          item('userAgent', 'User agent', ref.watch(userAgentStateProvider), type: 'text'),
          item('cfProxy', 'Cloudflare bypass proxy', CfProxyStore.url,
            type: 'text', detail: 'Optional FlareSolverr/Byparr HTTP URL'),
        ]));
        groups.add(group('Navigation', [
          item('navTooltips', 'Show navigation tooltips', ref.watch(showNavDoubleTapTooltipStateProvider)),
        ]));
      default:
        title = 'Settings';
    }
    _snapshot = {'title': title, 'sections': groups};
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _channel != null) {
        unawaited(_channel!.invokeMethod<void>('update', _snapshot));
      }
    });
    return UiKitView(
      viewType: 'novayomi/native-preferences',
      creationParams: _snapshot,
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: _created,
    );
  }
}
