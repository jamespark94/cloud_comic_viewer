import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_comic_viewer/models/comic_reading_history.dart';
import 'package:cloud_comic_viewer/models/cloud_account.dart';
import 'package:cloud_comic_viewer/services/reading_history_service.dart';
import 'package:cloud_comic_viewer/models/viewer_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('ReadingHistoryService Merge Tests', () {
    test('mergeWithRemote correctly resolves conflict with highest page and newest time', () async {
      final service = ReadingHistoryService.instance;
      await service.clearAll();

      final localTime = DateTime(2026, 10, 10, 10, 0);
      final remoteTime = DateTime(2026, 10, 10, 12, 0);

      // 로컬: 10페이지까지 읽음
      await service.updateProgress(
        id: 'comic_1',
        accountId: 'acc_1',
        accountName: 'Google Drive',
        cloudType: CloudType.googleDrive,
        title: 'One Piece 101.zip',
        pageIndex: 10,
        totalPages: 20,
      );

      final futureRemoteTime = DateTime.now().add(const Duration(hours: 2));

      // 원격: 15페이지까지 읽음, 더 최신 시간
      final remoteItem = ComicReadingHistory(
        id: 'comic_1',
        accountId: 'acc_1',
        accountName: 'Google Drive',
        cloudType: CloudType.googleDrive,
        title: 'One Piece 101.zip',
        lastPage: 15,
        totalPages: 20,
        lastReadAt: futureRemoteTime,
      );

      final remoteNewComic = ComicReadingHistory(
        id: 'comic_2',
        accountId: 'acc_1',
        accountName: 'Google Drive',
        cloudType: CloudType.googleDrive,
        title: 'Bleach 50.cbz',
        lastPage: 5,
        totalPages: 30,
        lastReadAt: DateTime.now(),
      );

      final merged = await service.mergeWithRemote([remoteItem, remoteNewComic]);

      // comic_1: 15페이지로 병합되어야 함
      final mergedItem1 = service.getHistory('comic_1');
      expect(mergedItem1, isNotNull);
      expect(mergedItem1!.lastPage, 15);
      expect(mergedItem1.lastReadAt, futureRemoteTime);

      // comic_2: 새로 추가되어야 함
      final mergedItem2 = service.getHistory('comic_2');
      expect(mergedItem2, isNotNull);
      expect(mergedItem2!.title, 'Bleach 50.cbz');

      expect(merged.length, 2);
    });

    test('mergeWithRemote retains local progress if local is further ahead', () async {
      final service = ReadingHistoryService.instance;
      await service.clearAll();

      // 로컬: 25페이지까지 읽음
      await service.updateProgress(
        id: 'comic_3',
        accountId: 'acc_1',
        accountName: 'Google Drive',
        cloudType: CloudType.googleDrive,
        title: 'Naruto 01.zip',
        pageIndex: 25,
        totalPages: 30,
      );

      // 원격: 이전 기기에서 10페이지만 읽힌 상태
      final remoteItem = ComicReadingHistory(
        id: 'comic_3',
        accountId: 'acc_1',
        accountName: 'Google Drive',
        cloudType: CloudType.googleDrive,
        title: 'Naruto 01.zip',
        lastPage: 10,
        totalPages: 30,
        lastReadAt: DateTime(2026, 10, 9),
      );

      await service.mergeWithRemote([remoteItem]);

      final item = service.getHistory('comic_3');
      expect(item, isNotNull);
      expect(item!.lastPage, 25); // 25페이지 유지 (뒤로 롤백되지 않음)
    });
  });

  group('PageNavigationMode Tests', () {
    test('enum contains expected values', () {
      expect(PageNavigationMode.values, contains(PageNavigationMode.leftRightTap));
      expect(PageNavigationMode.values, contains(PageNavigationMode.topBottomTap));
      expect(PageNavigationMode.values, contains(PageNavigationMode.swipeOnly));
    });
  });
}
