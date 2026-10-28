import 'package:mangayomi/l10n/generated/app_localizations.dart';
import 'package:mangayomi/repositories/settings_repository.dart';
import 'package:mangayomi/utils/localized_message.dart';

/// What the app can be busy with while it is off screen.
enum BackgroundWorkKind {
  download,
  libraryUpdate,
  restore,
  sync;

  /// The notification button stopping this work, if it can be stopped.
  String? get stopAction => switch (this) {
    download => 'cancel_downloads',
    libraryUpdate => 'stop_library_update',
    restore || sync => null,
  };
}

/// How far one kind of work has got.
class BackgroundWorkProgress {
  const BackgroundWorkProgress({
    this.done = 0,
    this.total = 0,
    this.current,
    this.detail,
  });

  /// Items finished out of [total]; 0 of 0 when there is no count.
  final int done;
  final int total;

  /// How far the item in progress is, 0 to 1.
  final double? current;

  /// What is being worked on, such as a chapter's title. Left out when the
  /// notification's content is hidden.
  final String? detail;
}

/// The single notification and foreground service shared by everything the
/// app does in the background.
///
/// Several kinds of work can run at once: the service starts with the first,
/// stops with the last, and its notification sums up all of them. Updates
/// are kept to one every [_updateInterval], as progress arrives much faster
/// than a notification is worth redrawing.
/// iOS does not use Android foreground-service notifications. These methods
/// remain available to the novel download, update, sync, and backup callers,
/// but the Android-only notification mechanism is intentionally inactive.
abstract final class BackgroundWork {
  static void Function(String action)? onAction;

  static bool isRunning(BackgroundWorkKind kind) => false;

  static bool get wantsReport => false;

  static bool get showsDetail =>
      !(settingsRepository.currentOrNull?.hideNotificationContent ?? false);

  static void begin(BackgroundWorkKind kind) {}

  static void report(BackgroundWorkKind kind, BackgroundWorkProgress progress) {}

  static void end(BackgroundWorkKind kind) {}

  static void handleAction(Object? action) {
    if (action is String) onAction?.call(action);
  }
}

String _label(AppLocalizations l10n, BackgroundWorkKind kind) => switch (kind) {
  BackgroundWorkKind.download => l10n.background_downloading,
  BackgroundWorkKind.libraryUpdate => l10n.background_updating_library,
  BackgroundWorkKind.restore => l10n.background_restoring,
  BackgroundWorkKind.sync => l10n.background_syncing,
};

/// The notification's title: what is going on, every kind of it.
String backgroundWorkTitle(
  AppLocalizations l10n,
  Iterable<BackgroundWorkKind> kinds,
) => kinds.map((kind) => _label(l10n, kind)).join(' · ');

/// The notification's text, one line per kind of work:
/// `5 / 12 · 42 %` then what is being worked on, unless [showDetail] is off.
/// With a single kind, the title already names it.
String backgroundWorkText(
  AppLocalizations l10n,
  Map<BackgroundWorkKind, BackgroundWorkProgress> work, {
  required bool showDetail,
}) {
  final lines = <String>[];
  for (final MapEntry(key: kind, value: progress) in work.entries) {
    final parts = [
      if (work.length > 1) _label(l10n, kind),
      if (progress.total > 0) '${progress.done} / ${progress.total}',
      if (progress.current case final current?)
        '${(current.clamp(0, 1) * 100).floor()} %',
      if (showDetail && (progress.detail?.isNotEmpty ?? false))
        progress.detail!,
    ];
    if (parts.isNotEmpty) lines.add(parts.join(' · '));
  }
  return lines.isEmpty ? l10n.background_work_in_progress : lines.join('\n');
}
