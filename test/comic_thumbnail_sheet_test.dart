import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cloud_comic_viewer/models/comic_page.dart';
import 'package:cloud_comic_viewer/ui/widgets/comic_thumbnail_sheet.dart';

// Valid 1x1 transparent PNG
final _dummyPngBytes = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

List<ComicPage> _buildPages(int count) {
  return List.generate(
    count,
    (index) => ComicPage(
      index: index,
      name: 'page_${index + 1}.png',
      initialBytes: _dummyPngBytes,
    ),
  );
}

void main() {
  group('ComicThumbnailSheet.computeInitialScrollOffset', () {
    test('returns 0 when pageCount is 0 or dimensions are non-positive', () {
      expect(
        ComicThumbnailSheet.computeInitialScrollOffset(
          pageCount: 0,
          currentPageIndex: 0,
          viewportWidth: 400,
          viewportHeight: 500,
        ),
        0.0,
      );
      expect(
        ComicThumbnailSheet.computeInitialScrollOffset(
          pageCount: 10,
          currentPageIndex: 5,
          viewportWidth: 0,
          viewportHeight: 500,
        ),
        0.0,
      );
    });

    test('returns 0 when all items fit inside viewport', () {
      expect(
        ComicThumbnailSheet.computeInitialScrollOffset(
          pageCount: 3,
          currentPageIndex: 2,
          viewportWidth: 400,
          viewportHeight: 600,
        ),
        0.0,
      );
    });

    test('clamps out-of-range page index safely', () {
      final lastPageOffset = ComicThumbnailSheet.computeInitialScrollOffset(
        pageCount: 60,
        currentPageIndex: 59,
        viewportWidth: 400,
        viewportHeight: 500,
      );
      final overIndexOffset = ComicThumbnailSheet.computeInitialScrollOffset(
        pageCount: 60,
        currentPageIndex: 999,
        viewportWidth: 400,
        viewportHeight: 500,
      );
      expect(overIndexOffset, equals(lastPageOffset));
      expect(overIndexOffset, greaterThan(0.0));
    });
  });

  group('ComicThumbnailSheet widget', () {
    testWidgets('centers around currentPageIndex on open so surrounding pages are visible', (tester) async {
      final pages = _buildPages(60);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 500,
              child: ComicThumbnailSheet(
                pages: pages,
                currentPageIndex: 30, // 31p
                onPageSelected: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Current page and adjacent rows before/after should be visible immediately
      expect(find.text('31p'), findsOneWidget);
      expect(find.text('28p'), findsOneWidget);
      expect(find.text('34p'), findsOneWidget);
      // Page 1 should not be built/visible at the top
      expect(find.text('1p'), findsNothing);
    });

    testWidgets('shows last pages cleanly without overscroll when on the last page', (tester) async {
      final pages = _buildPages(60);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 500,
              child: ComicThumbnailSheet(
                pages: pages,
                currentPageIndex: 59, // 60p
                onPageSelected: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('60p'), findsOneWidget);
      expect(find.text('55p'), findsOneWidget);
      expect(find.text('1p'), findsNothing);

      final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
      expect(
        scrollable.position.pixels,
        closeTo(scrollable.position.maxScrollExtent, 1.0),
      );
    });

    testWidgets('starts at top when on the first page', (tester) async {
      final pages = _buildPages(60);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 500,
              child: ComicThumbnailSheet(
                pages: pages,
                currentPageIndex: 0, // 1p
                onPageSelected: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('1p'), findsOneWidget);
      final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
      expect(scrollable.position.pixels, 0.0);
    });
  });
}
