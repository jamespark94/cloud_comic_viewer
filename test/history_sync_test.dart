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

    test('Tombstone prevents deleted history from reviving when syncing with remote', () async {
      final service = ReadingHistoryService.instance;
      await service.clearAll();

      // 1. 만화 읽기 기록 추가
      await service.updateProgress(
        id: 'comic_delete_1',
        accountId: 'acc_1',
        accountName: 'Google Drive',
        cloudType: CloudType.googleDrive,
        title: 'Hunter x Hunter 01.zip',
        pageIndex: 12,
        totalPages: 24,
      );
      expect(service.getHistory('comic_delete_1'), isNotNull);

      // 2. 로컬에서 삭제 (툼스톤 등록)
      await service.removeHistory('comic_delete_1', title: 'Hunter x Hunter 01.zip');
      expect(service.getHistory('comic_delete_1'), isNull);

      final deletedRecords = await service.getDeletedRecords();
      expect(deletedRecords.containsKey('comic_delete_1'), isTrue);
      expect(deletedRecords.containsKey('Hunter x Hunter 01.zip'), isTrue);

      // 3. 원격 서버에서 아직 삭제 안 된 이전 기록이 동기화로 들어옴
      final staleRemoteItem = ComicReadingHistory(
        id: 'comic_delete_1',
        accountId: 'acc_1',
        accountName: 'Google Drive',
        cloudType: CloudType.googleDrive,
        title: 'Hunter x Hunter 01.zip',
        lastPage: 12,
        totalPages: 24,
        lastReadAt: DateTime.now().subtract(const Duration(minutes: 5)),
      );

      final merged = await service.mergeWithRemote([staleRemoteItem]);

      // 4. 툼스톤 덕분에 좀비처럼 부활하지 않아야 함
      expect(merged.any((h) => h.id == 'comic_delete_1'), isFalse);
      expect(service.getHistory('comic_delete_1'), isNull);
    });

    test('Remote deleted records properly deletes local history', () async {
      final service = ReadingHistoryService.instance;
      await service.clearAll();

      // 1. 로컬에 존재하는 기록
      await service.updateProgress(
        id: 'comic_remote_del',
        accountId: 'acc_1',
        accountName: 'Google Drive',
        cloudType: CloudType.googleDrive,
        title: 'Dragon Ball 01.zip',
        pageIndex: 5,
        totalPages: 30,
      );
      expect(service.getHistory('comic_remote_del'), isNotNull);

      // 2. 원격에서 삭제된 툼스톤 전달 (현재 시점)
      final remoteDeleted = {
        'comic_remote_del': DateTime.now().millisecondsSinceEpoch,
      };

      await service.mergeWithRemote([], remoteDeletedRecords: remoteDeleted);

      // 3. 로컬에서도 삭제되었는지 확인
      expect(service.getHistory('comic_remote_del'), isNull);
      final localDeleted = await service.getDeletedRecords();
      expect(localDeleted.containsKey('comic_remote_del'), isTrue);
    });

    test('Title-based tombstone matches and removes history from different id/device', () async {
      final service = ReadingHistoryService.instance;
      await service.clearAll();

      // 1. 로컬에서 title: "Slam Dunk 01.zip" 삭제
      await service.removeHistory('deviceA_id_999', title: 'Slam Dunk 01.zip');

      // 2. 원격에서 다른 기기/다른 ID의 동일 제목 기록이 들어옴
      final otherDeviceIdItem = ComicReadingHistory(
        id: 'deviceB_id_888',
        accountId: 'acc_2',
        accountName: 'OneDrive',
        cloudType: CloudType.oneDrive,
        title: 'Slam Dunk 01.zip',
        lastPage: 20,
        totalPages: 30,
        lastReadAt: DateTime.now().subtract(const Duration(hours: 1)),
      );

      final merged = await service.mergeWithRemote([otherDeviceIdItem]);

      // 3. 제목 기반 매칭으로 제외되어야 함
      expect(merged.any((h) => h.title == 'Slam Dunk 01.zip'), isFalse);
      expect(service.getHistory('deviceB_id_888'), isNull);
    });

    test('Reading again after deletion clears tombstone and revives history', () async {
      final service = ReadingHistoryService.instance;
      await service.clearAll();

      // 1. 삭제
      await service.removeHistory('comic_reread', title: 'Re-read Comic.zip');
      var deleted = await service.getDeletedRecords();
      expect(deleted.containsKey('comic_reread'), isTrue);

      // 2. 사용자가 다시 읽음 -> 툼스톤 해제
      await service.updateProgress(
        id: 'comic_reread',
        accountId: 'acc_1',
        accountName: 'Google Drive',
        cloudType: CloudType.googleDrive,
        title: 'Re-read Comic.zip',
        pageIndex: 1,
        totalPages: 20,
      );

      deleted = await service.getDeletedRecords();
      expect(deleted.containsKey('comic_reread'), isFalse);
      expect(deleted.containsKey('Re-read Comic.zip'), isFalse);
      expect(service.getHistory('comic_reread'), isNotNull);
    });
  });

  group('PageNavigationMode Tests', () {
    test('enum contains expected values', () {
      expect(PageNavigationMode.values, contains(PageNavigationMode.leftRightTap));
      expect(PageNavigationMode.topBottomTap, isNotNull);
      expect(PageNavigationMode.swipeOnly, isNotNull);
    });
  });
}
