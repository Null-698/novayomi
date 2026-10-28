import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/modules/browse/extension/widgets/extension_templates.dart';

void main() {
  test('Dart novel source template retains HTML and required bridge hooks', () {
    expect(dartExtensionTemplate, contains('getHtmlContent(String name, String url)'));
    expect(dartExtensionTemplate, contains('cleanHtmlContent(String html)'));
    expect(dartExtensionTemplate, contains('getVideoList(String url) async {'));
    expect(dartExtensionTemplate, contains('getPageList(String url) async {'));
    expect(dartExtensionTemplate, isNot(contains('streamWishExtractor')));
  });

  test('JavaScript novel template contains only novel content methods', () {
    final source = Source(
      name: 'Novel source',
      lang: 'en',
      baseUrl: 'https://example.com',
      itemType: ItemType.novel,
    );
    final template = jsExtensionTemplate(source);
    expect(template, contains('"itemType": ${ItemType.novel.index}'));
    expect(template, contains('async getHtmlContent(name, url)'));
    expect(template, contains('async cleanHtmlContent(html)'));
    expect(template, isNot(contains('getVideoList(')));
    expect(template, isNot(contains('getPageList(')));
    expect(template, isNot(contains('streamWishExtractor')));
  });
}
