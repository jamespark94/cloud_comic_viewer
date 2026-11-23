import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_comic_viewer/models/cloud_account.dart';
import 'package:cloud_comic_viewer/models/media_item.dart';
import 'package:cloud_comic_viewer/models/viewer_settings.dart';
import 'package:cloud_comic_viewer/services/cloud_service_interface.dart';
import 'package:cloud_comic_viewer/services/viewer_settings_service.dart';
import 'package:cloud_comic_viewer/ui/screens/comic_viewer_screen.dart';

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

class _FakeCloudService extends CloudService {
  final List<MediaItem> items;

  _FakeCloudService(this.items)
      : super(
          CloudAccount(
            id: 'fake-account',
            name: 'Fake',
            type: CloudType.webDav,
            email: 'fake@example.com',
            accessToken: '',
          ),
        );

  @override
  Future<Uint8List> downloadBytes(
    MediaItem item, {
    void Function(int received, int total)? onProgress,
  }) async {
    return _dummyPngBytes;
  }

  @override
  Future<Map<String, String>> getStreamHeaders() async => {};

  @override
  Future<String> getStreamUrl(MediaItem item) async => 'https://example.com/${item.id}';

  @override
  Future<List<MediaItem>> listItems({String? folderId}) async => items;

  @override
  Future<bool> refreshTokensIfNeeded() async => true;
}

List<MediaItem> _buildImageItems(int count) {
  return List.generate(
    count,
    (index) => MediaItem(
      id: 'img_${index + 1}',
      name: '00${index + 1}.png',
      parentId: 'folder_1',
      isFolder: false,
      mimeType: 'image/png',
    ),
  );
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ViewerSettingsService.instance.updateSettings(
      const ViewerSettings(
        readingDirection: ReadingDirection.leftToRight,
        viewerMode: ViewerMode.singlePage,
        displayMode: PageDisplayMode.auto,
        translationMode: ComicTranslationMode.off,
      ),
    );
  });

  testWidgets('portrait phone top bar displays page info as a single horizontal line below title', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final items = _buildImageItems(3);
    final service = _FakeCloudService(items);

    await tester.pumpWidget(
      MaterialApp(
        home: ComicViewerScreen(
          item: items.first,
          service: service,
          folderSiblings: items,
          parentFolderId: 'folder_1',
          currentFolderName: '테스트 만화 제목이 꽤 긴 경우에도 가로로 잘 나와야 합니다',
        ),
      ),
    );
    await tester.pumpAndSettle();

    final titleFinder = find.textContaining('테스트 만화 제목');
    final pageInfoFinder = find.text('1p / 3 페이지  •  자동 (비율/방향 맞춤)');

    expect(titleFinder, findsOneWidget);
    expect(pageInfoFinder, findsOneWidget);

    final titleBox = tester.getRect(titleFinder);
    final pageInfoBox = tester.getRect(pageInfoFinder);

    // Page info sits below the title and renders on one horizontal line (not stacked vertically)
    expect(pageInfoBox.top, greaterThan(titleBox.top));
    expect(pageInfoBox.height, lessThan(24.0));
    expect(pageInfoBox.width, greaterThan(150.0));

    // Even when AI translation adds 2 extra action icons, page info stays horizontal
    await ViewerSettingsService.instance.setTranslationMode(ComicTranslationMode.auto);
    await tester.pumpAndSettle();

    final pageInfoBoxWithTranslation = tester.getRect(pageInfoFinder);
    expect(pageInfoBoxWithTranslation.height, lessThan(24.0));
    expect(pageInfoBoxWithTranslation.width, greaterThan(150.0));
  });

  testWidgets('bottom navigation arrows reverse in rightToLeft (Japanese manga) mode', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final items = _buildImageItems(3);
    final service = _FakeCloudService(items);

    await tester.pumpWidget(
      MaterialApp(
        home: ComicViewerScreen(
          item: items.first,
          service: service,
          folderSiblings: items,
          parentFolderId: 'folder_1',
          currentFolderName: '일본 만화 테스트',
        ),
      ),
    );
    await tester.pumpAndSettle();

    final leftArrow = find.byIcon(Icons.navigate_before);
    final rightArrow = find.byIcon(Icons.navigate_next);

    // 1. Standard LTR: right arrow -> next page, left arrow -> previous page
    expect(find.text('1p / 3 페이지  •  자동 (비율/방향 맞춤)'), findsOneWidget);
    await tester.tap(rightArrow);
    await tester.pumpAndSettle();
    expect(find.text('2p / 3 페이지  •  자동 (비율/방향 맞춤)'), findsOneWidget);

    await tester.tap(leftArrow);
    await tester.pumpAndSettle();
    expect(find.text('1p / 3 페이지  •  자동 (비율/방향 맞춤)'), findsOneWidget);

    // 2. Japanese RTL: left arrow -> next page, right arrow -> previous page
    await ViewerSettingsService.instance.setReadingDirection(ReadingDirection.rightToLeft);
    await tester.pumpAndSettle();

    // On page 1 in RTL, right arrow (previous) is disabled, left arrow (next) goes to page 2
    final rightButtonOnPage1 = tester.widget<IconButton>(find.ancestor(of: rightArrow, matching: find.byType(IconButton)));
    expect(rightButtonOnPage1.onPressed, isNull);

    await tester.tap(leftArrow);
    await tester.pumpAndSettle();
    expect(find.text('2p / 3 페이지  •  자동 (비율/방향 맞춤)'), findsOneWidget);

    await tester.tap(rightArrow);
    await tester.pumpAndSettle();
    expect(find.text('1p / 3 페이지  •  자동 (비율/방향 맞춤)'), findsOneWidget);
  });
}
