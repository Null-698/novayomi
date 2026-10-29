import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/services/volume_keys.dart';
import 'package:mangayomi/utils/extensions/manga_extensions.dart';
import 'package:mangayomi/models/settings.dart';
import 'package:mangayomi/modules/novel/novel_reader_controller_provider.dart';
import 'package:mangayomi/providers/reader_state_provider.dart';
import 'package:mangayomi/services/get_html_content.dart';
import 'package:mangayomi/src/rust/api/epub.dart';
import 'package:mangayomi/utils/utils.dart';

/// Data-only Flutter bridge for the full-screen UIKit / WKWebView reader.
/// Flutter never renders iOS novel text, bars, overlays or scroll effects.
class NativeNovelReaderScreen extends ConsumerStatefulWidget {
  const NativeNovelReaderScreen({
    super.key,
    required this.chapter,
    required this.result,
  });

  final Chapter chapter;
  final AsyncValue<(String, EpubNovel?)> result;

  @override
  ConsumerState<NativeNovelReaderScreen> createState() =>
      _NativeNovelReaderScreenState();
}

class _NativeNovelReaderScreenState extends ConsumerState<NativeNovelReaderScreen> {
  static const _channel = MethodChannel('novayomi/native-reader');
  static Future<String>? _openDyslexicAsset;

  late Chapter _chapter;
  late final Stopwatch _readingTime;
  double _progress = 0;
  bool _opening = false;
  bool _presented = false;
  bool _busy = false;
  bool _closing = false;
  String? _error;
  DateTime _lastSavedAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _chapter = widget.chapter;
    _progress = double.tryParse(_chapter.lastPageRead ?? '')?.clamp(0.0, 1.0).toDouble() ?? 0;
    _readingTime = Stopwatch()..start();
    _channel.setMethodCallHandler(_onNativeCall);
  }

  @override
  void didUpdateWidget(covariant NativeNovelReaderScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_presented && !_opening && widget.result.hasValue) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _startIfReady();
      });
    }
  }

  @override
  void dispose() {
    _readingTime.stop();
    unawaited(VolumeKeys.disable());
    _channel.setMethodCallHandler(null);
    super.dispose();
  }

  NovelReaderController get _controller =>
      ref.read(novelReaderControllerProvider(chapter: _chapter).notifier);

  void _startIfReady() {
    if (!mounted || _opening || _presented || _closing) return;
    final result = widget.result;
    if (result is AsyncData<(String, EpubNovel?)>) {
      unawaited(_open(result.value));
    }
  }

  Future<void> _open((String, EpubNovel?) data) async {
    if (_opening || _presented || !mounted) return;
    _opening = true;
    try {
      await _channel.invokeMethod<void>('open', await _buildPayload(_chapter, data));
      if (mounted) {
        _presented = true;
        unawaited(_syncVolumeKeys());
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      _opening = false;
    }
  }

  Future<Map<String, Object?>> _buildPayload(
    Chapter chapter,
    (String, EpubNovel?) data,
  ) async {
    final fontData = await (_openDyslexicAsset ??= _loadOpenDyslexicFont());
    final controller = ref.read(
      novelReaderControllerProvider(chapter: chapter).notifier,
    );
    final novel = chapter.manga.value;
    final url = Uri.tryParse(chapter.url ?? '');
    final source = (novel?.lang != null && novel?.source != null)
        ? getSource(novel!.lang!, novel.source!, novel.sourceId, installedOnly: true)
        : null;
    final sourceUrl = Uri.tryParse(source?.baseUrl ?? '');
    final baseURL = (url != null && (url.scheme == 'https' || url.scheme == 'http'))
        ? url
        : (sourceUrl != null &&
                (sourceUrl.scheme == 'https' || sourceUrl.scheme == 'http'))
            ? sourceUrl
            : null;
    // The native sheet must see the *entire* reading-order list, not only a
    // sliding window of 25 entries around the current chapter.
    final preferred = novel?.getChapterListForReading(current: chapter) ?? <Chapter>[];
    final knownIds = preferred.map((c) => c.id).toSet();
    // The picker must list every actual chapter, even if reading preferences
    // would skip read or duplicate chapters for Next/Previous navigation.
    final chapters = <Chapter>[
      ...preferred,
      for (final c in novel?.chapters.toList() ?? <Chapter>[])
        if (!knownIds.contains(c.id)) c,
    ];
    final index = chapters.indexWhere((c) => c.id == chapter.id);
    final auto = controller.autoScrollValues();
    final pageLayout = ref.read(doublePageAutoStateProvider)
        ? 'auto'
        : controller.getPageMode() == PageMode.doublePage ? 'double' : 'single';

    return <String, Object?>{
      'title': novel?.name ?? 'Novel',
      'subtitle': chapter.name ?? '',
      'html': _prepareHtml(data.$1, data.$2),
      'chapterId': chapter.id,
      'chapterIndex': index >= 0 ? index + 1 : 0,
      'chapterCount': chapters.length,
      'progress': double.tryParse(chapter.lastPageRead ?? '')?.clamp(0.0, 1.0).toDouble() ?? 0,
      'bookmarked': controller.getChapterBookmarked(),
      'hasPrevious': controller.hasPreviousChapter,
      'hasNext': controller.hasNextChapter,
      'mode': controller.getReaderMode().isContinuous ? 'scroll' : 'pages',
      'fontSize': ref.read(novelFontSizeStateProvider),
      'lineHeight': ref.read(novelReaderLineHeightStateProvider),
      'padding': ref.read(novelReaderPaddingStateProvider),
      'background': ref.read(novelReaderThemeStateProvider),
      'foreground': ref.read(novelReaderTextColorStateProvider),
      'compactParagraphs': ref.read(novelRemoveExtraParagraphSpacingStateProvider),
      'alignment': ref.read(novelTextAlignStateProvider).name == 'block'
          ? 'justify'
          : ref.read(novelTextAlignStateProvider).name,
      'fontFamily': ref.read(novelFontFamilyStateProvider) ?? '',
      'fontData': fontData,
      'pageLayout': pageLayout,
      'keepAwake': ref.read(keepScreenOnReaderStateProvider),
      'showPercent': ref.read(novelShowScrollPercentageStateProvider),
      'tapZones': ref.read(novelTapToScrollStateProvider),
      'volumeKeys': ref.read(volumeKeysPagingStateProvider),
      'invertVolume': ref.read(volumeKeysInvertedStateProvider),
      'orientation': ref.read(readerOrientationStateProvider),
      'autoScroll': auto.$1,
      'autoScrollSpeed': auto.$2,
      'ttsSpeed': ref.read(ttsSpeechRateStateProvider),
      'ttsPitch': ref.read(ttsPitchStateProvider),
      'ttsLanguage': ref.read(ttsLanguageStateProvider),
      if (baseURL != null) 'baseURL': baseURL.toString(),
      'chapters': [
        for (final entry in chapters)
          if (entry.id != null)
            <String, Object?>{
              'id': entry.id,
              'title': entry.name ?? 'Chapter',
            },
      ],
    };
  }

  Future<String> _loadOpenDyslexicFont() async {
    try {
      final file = await rootBundle.load(
        'assets/fonts/OpenDyslexic/OpenDyslexic-Regular.otf',
      );
      return base64Encode(
        file.buffer.asUint8List(file.offsetInBytes, file.lengthInBytes),
      );
    } catch (_) {
      return '';
    }
  }

  String _prepareHtml(String source, EpubNovel? book) {
    final document = html_parser.parse(source);
    // Preserve the behavior of flutter_html: content is markup, never code.
    for (final element in document.querySelectorAll(
      'script, iframe, object, embed, form, link, meta, base',
    )) {
      element.remove();
    }
    for (final element in document.querySelectorAll('*')) {
      for (final key in element.attributes.keys.toList()) {
        final attributeName = key.toString().toLowerCase();
        if (attributeName.startsWith('on') || attributeName == 'srcdoc') {
          element.attributes.remove(key);
        }
      }
    }
    // Embed only EPUB images referenced by this chapter.
    if (book != null) {
      for (final image in document.querySelectorAll('img')) {
        final src = image.attributes['src'] ?? '';
        if (src.isEmpty || src.startsWith('data:')) continue;
        final name = Uri.tryParse(src)?.pathSegments.last ?? src.split('/').last;
        EpubResource? found;
        for (final candidate in book.images) {
          if (candidate.name.endsWith(name) ||
              candidate.name.contains(name.replaceAll('%20', ' '))) {
            found = candidate;
            break;
          }
        }
        if (found == null) continue;
        final ext = name.split('.').last.toLowerCase();
        final mime = switch (ext) {
          'png' => 'image/png',
          'gif' => 'image/gif',
          'webp' => 'image/webp',
          'svg' => 'image/svg+xml',
          _ => 'image/jpeg',
        };
        image.attributes['src'] = 'data:$mime;base64,${base64Encode(found.content)}';
      }
    }
    return document.body?.innerHtml ?? source;
  }

  Future<dynamic> _onNativeCall(MethodCall call) async {
    if (call.method != 'event' || !mounted || _closing) return null;
    final payload = Map<String, dynamic>.from(call.arguments as Map);
    switch (payload['type'] as String? ?? '') {
      case 'progress':
        final raw = payload['value'] as num?;
        if (raw == null) break;
        _progress = raw.toDouble().clamp(0.0, 1.0).toDouble();
        final now = DateTime.now();
        if (now.difference(_lastSavedAt) >= const Duration(seconds: 15)) {
          _lastSavedAt = now;
          _controller.setChapterOffset(_progress * 1000, 1000, true);
        }
      case 'bookmark':
        _controller.setChapterBookmarked();
      case 'fontSize':
        final size = payload['value'] as int?;
        if (size != null) {
          ref.read(novelFontSizeStateProvider.notifier).set(size);
        }
      case 'lineHeight':
        final height = (payload['value'] as num?)?.toDouble();
        if (height != null) {
          ref.read(novelReaderLineHeightStateProvider.notifier).set(height);
        }
      case 'padding':
        final padding = payload['value'] as int?;
        if (padding != null) {
          ref.read(novelReaderPaddingStateProvider.notifier).set(padding);
        }
      case 'background':
        final color = payload['value'] as String?;
        if (color != null) {
          ref.read(novelReaderThemeStateProvider.notifier).set(color);
        }
      case 'foreground':
        final color = payload['value'] as String?;
        if (color != null) {
          ref.read(novelReaderTextColorStateProvider.notifier).set(color);
        }
      case 'fontFamily':
        final value = payload['value'] as String?;
        if (value != null) {
          ref.read(novelFontFamilyStateProvider.notifier)
              .set(value.isEmpty ? null : value);
        }
      case 'pageLayout':
        final layout = payload['value'] as String?;
        if (layout != null) {
          ref.read(doublePageAutoStateProvider.notifier).set(layout == 'auto');
          _controller.setPageMode(
            layout == 'double' ? PageMode.doublePage : PageMode.onePage,
          );
        }
      case 'keepAwake':
        final enabled = payload['value'] as bool?;
        if (enabled != null) {
          ref.read(keepScreenOnReaderStateProvider.notifier).set(enabled);
        }
      case 'showPercent':
        final enabled = payload['value'] as bool?;
        if (enabled != null) {
          ref.read(novelShowScrollPercentageStateProvider.notifier).set(enabled);
        }
      case 'tapZones':
        final enabled = payload['value'] as bool?;
        if (enabled != null) {
          ref.read(novelTapToScrollStateProvider.notifier).set(enabled);
        }
      case 'volumeKeys':
        final enabled = payload['value'] as bool?;
        if (enabled != null) {
          ref.read(volumeKeysPagingStateProvider.notifier).set(enabled);
          unawaited(_syncVolumeKeys());
        }
      case 'invertVolume':
        final enabled = payload['value'] as bool?;
        if (enabled != null) {
          ref.read(volumeKeysInvertedStateProvider.notifier).set(enabled);
        }
      case 'orientation':
        final orientation = payload['value'] as int?;
        if (orientation != null) {
          ref.read(readerOrientationStateProvider.notifier).set(orientation);
        }
      case 'compactParagraphs':
        final enabled = payload['value'] as bool?;
        if (enabled != null) {
          ref.read(novelRemoveExtraParagraphSpacingStateProvider.notifier).set(enabled);
        }
      case 'autoScroll':
        final enabled = payload['value'] as bool?;
        if (enabled != null) {
          final settings = _controller.autoScrollValues();
          _controller.setAutoScroll(enabled, settings.$2);
        }
      case 'autoScrollSpeed':
        final speed = (payload['value'] as num?)?.toDouble();
        if (speed != null) {
          final settings = _controller.autoScrollValues();
          _controller.setAutoScroll(settings.$1, speed);
        }
      case 'ttsSpeed':
        final speed = (payload['value'] as num?)?.toDouble();
        if (speed != null) ref.read(ttsSpeechRateStateProvider.notifier).set(speed);
      case 'ttsPitch':
        final pitch = (payload['value'] as num?)?.toDouble();
        if (pitch != null) ref.read(ttsPitchStateProvider.notifier).set(pitch);
      case 'ttsLanguage':
        final language = payload['value'] as String?;
        if (language != null) {
          ref.read(ttsLanguageStateProvider.notifier)
              .set(language.isEmpty ? null : language);
        }
      case 'alignment':
        final align = payload['value'] as String?;
        if (align != null) {
          final style = switch (align) {
            'center' => NovelTextAlign.center,
            'right' => NovelTextAlign.right,
            'justify' => NovelTextAlign.block,
            _ => NovelTextAlign.left,
          };
          ref.read(novelTextAlignStateProvider.notifier).set(style);
        }
      case 'mode':
        final mode = payload['value'] as String?;
        if (mode == 'scroll' || mode == 'pages') {
          _controller.setReaderMode(
            mode == 'scroll' ? ReaderMode.verticalContinuous : ReaderMode.ltr,
          );
        }
      case 'previous':
        unawaited(_navigate(forward: false));
      case 'next':
        unawaited(_navigate(forward: true));
      case 'chapter':
        final id = payload['id'] as int?;
        if (id != null) unawaited(_navigate(id: id));
      case 'closed':
        unawaited(_closeFromNative());
    }
    return null;
  }

  Future<void> _syncVolumeKeys() async {
    if (!mounted || !_presented) return;
    if (!ref.read(volumeKeysPagingStateProvider)) {
      await VolumeKeys.disable();
      return;
    }
    await VolumeKeys.enable((up) {
      if (!mounted || !_presented || _closing) return;
      final inverted = ref.read(volumeKeysInvertedStateProvider);
      unawaited(_channel.invokeMethod<void>(
        'volumeKey', <String, Object?>{'forward': up != inverted},
      ).catchError((Object _) {}));
    });
  }

  Future<void> _persistChapter() async {
    final controller = _controller;
    controller.setChapterOffset(_progress * 1000, 1000, true);
    await controller.setHistoryUpdate(elapsedSeconds: _readingTime.elapsed.inSeconds);
    _readingTime
      ..reset()
      ..start();
  }

  Future<void> _navigate({bool? forward, int? id}) async {
    if (_busy || !mounted || _closing) return;
    final controller = _controller;
    Chapter? target;
    if (id != null) {
      if (_chapter.id == id) return;
      for (final c in _chapter.manga.value?.getChapterListForReading(current: _chapter) ?? <Chapter>[]) {
        if (c.id == id) {
          target = c;
          break;
        }
      }
    } else if (forward == true && controller.hasNextChapter) {
      target = controller.getNextChapter();
    } else if (forward == false && controller.hasPreviousChapter) {
      target = controller.getPrevChapter();
    }
    if (target == null) return;
    _busy = true;
    try {
      final data = await ref.read(getHtmlContentProvider(chapter: target).future);
      if (!mounted || _closing) return;
      await _persistChapter();
      if (!mounted || _closing) return;
      final next = await _buildPayload(target, data);
      await _channel.invokeMethod<void>('replaceChapter', next);
      _chapter = target;
      _progress = (next['progress'] as num?)?.toDouble() ?? 0;
      _lastSavedAt = DateTime.fromMillisecondsSinceEpoch(0);
    } catch (error) {
      if (mounted && !_closing) {
        await _channel.invokeMethod<void>('showError', error.toString());
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _closeFromNative() async {
    if (_closing) return;
    _closing = true;
    try {
      await VolumeKeys.disable();
      await _persistChapter();
    } finally {
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.result.when(
      data: (data) {
        if (!_presented && !_opening && !_closing && _error == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _startIfReady());
        }
        return Scaffold(
          body: Center(
            child: _error == null
                ? const CircularProgressIndicator()
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Unable to open native reader: $_error'),
                      TextButton(
                        onPressed: () {
                          setState(() => _error = null);
                          _startIfReady();
                        },
                        child: const Text('Retry native reader'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Close'),
                      ),
                    ],
                  ),
          ),
        );
      },
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (error, stack) => Scaffold(
        body: Center(child: Text('Unable to load chapter: $error')),
      ),
    );
  }
}
