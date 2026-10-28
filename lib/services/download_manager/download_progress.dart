import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/page.dart';

/// Messages exchanged with chapter-download workers.
class DownloadComplete {}

class DownloadProgress {
  PageUrl? pageUrl;
  final int completed;
  final int total;
  bool isCompleted;
  ItemType itemType;

  DownloadProgress(
    this.completed,
    this.total,
    this.itemType, {
    this.pageUrl,
    this.isCompleted = false,
  });

  @override
  String toString() =>
      'DownloadProgress(pageUrl: $pageUrl completed: $completed, total: $total, isCompleted: $isCompleted)';
}
