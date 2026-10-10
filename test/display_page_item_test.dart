import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cloud_comic_viewer/models/comic_page.dart';
import 'package:cloud_comic_viewer/models/display_page_item.dart';
import 'package:cloud_comic_viewer/models/viewer_settings.dart';
import 'package:cloud_comic_viewer/utils/image_dimension_utils.dart';

void main() {
  group('DisplayPageBuilder Tests', () {
    final normalPage1 = ComicPage(index: 0, name: '01.jpg');
    final normalPage2 = ComicPage(index: 1, name: '02.jpg');
    final widePage = ComicPage(index: 2, name: '03.jpg')
      ..updateDimensions(const ImageDimensions(2000, 1000)); // isWide = true

    final pages = [normalPage1, normalPage2, widePage];

    test('single mode returns 1:1 mapping', () {
      final items = DisplayPageBuilder.buildItems(
        pages: pages,
        mode: PageDisplayMode.single,
        direction: ReadingDirection.leftToRight,
        orientation: Orientation.portrait,
      );
      expect(items.length, 3);
      expect(items[0].type, DisplayItemType.single);
      expect(items[2].type, DisplayItemType.single);
    });

    test('split mode divides each page into 2 slices', () {
      // RtoL: right slice first, then left slice
      final items = DisplayPageBuilder.buildItems(
        pages: [normalPage1],
        mode: PageDisplayMode.split,
        direction: ReadingDirection.rightToLeft,
        orientation: Orientation.portrait,
      );
      expect(items.length, 2);
      expect(items[0].type, DisplayItemType.splitRight);
      expect(items[1].type, DisplayItemType.splitLeft);
    });

    test('spread mode pairs pages', () {
      // 3 pages => 2 display items (first two paired, last single)
      final items = DisplayPageBuilder.buildItems(
        pages: pages,
        mode: PageDisplayMode.spread,
        direction: ReadingDirection.rightToLeft,
        orientation: Orientation.landscape,
      );
      expect(items.length, 2);
      expect(items[0].type, DisplayItemType.spread);
      // RtoL: leftPage is page 1, rightPage is page 0
      expect(items[0].leftPage.index, 1);
      expect(items[0].rightPage?.index, 0);
      expect(items[1].type, DisplayItemType.single);
    });

    test('auto mode portrait splits wide pages only', () {
      final items = DisplayPageBuilder.buildItems(
        pages: pages,
        mode: PageDisplayMode.auto,
        direction: ReadingDirection.rightToLeft,
        orientation: Orientation.portrait,
      );
      // normalPage1 (single), normalPage2 (single), widePage (splitRight, splitLeft) => 4 items
      expect(items.length, 4);
      expect(items[0].type, DisplayItemType.single);
      expect(items[1].type, DisplayItemType.single);
      expect(items[2].type, DisplayItemType.splitRight);
      expect(items[3].type, DisplayItemType.splitLeft);
    });

    test('findDisplayIndex maps correctly', () {
      final items = DisplayPageBuilder.buildItems(
        pages: pages,
        mode: PageDisplayMode.auto,
        direction: ReadingDirection.rightToLeft,
        orientation: Orientation.portrait,
      );
      expect(DisplayPageBuilder.findDisplayIndex(items, 0), 0);
      expect(DisplayPageBuilder.findDisplayIndex(items, 1), 1);
      expect(DisplayPageBuilder.findDisplayIndex(items, 2), 2);
    });
  });
}
