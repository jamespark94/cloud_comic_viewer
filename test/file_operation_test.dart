import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:cloud_comic_viewer/models/cloud_account.dart';
import 'package:cloud_comic_viewer/models/media_item.dart';
import 'package:cloud_comic_viewer/services/local_disk_service.dart';

void main() {
  group('LocalDiskService File Operations Tests', () {
    late Directory tempDir;
    late LocalDiskService service;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('comic_test_');
      final account = CloudAccount(
        id: 'local_test',
        name: 'Local Test',
        type: CloudType.local,
        email: 'local@device',
        accessToken: '',
      );
      service = LocalDiskService(account);
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('createFolder creates a new folder inside parent directory', () async {
      final success = await service.createFolder('NewMangaFolder', parentFolderId: tempDir.path);
      expect(success, isTrue);

      final createdDir = Directory('${tempDir.path}${Platform.pathSeparator}NewMangaFolder');
      expect(createdDir.existsSync(), isTrue);
    });

    test('renameItem renames a file properly', () async {
      final file = File('${tempDir.path}${Platform.pathSeparator}vol01.zip');
      file.writeAsStringSync('dummy zip content');

      final item = MediaItem(
        id: file.path,
        name: 'vol01.zip',
        isFolder: false,
      );

      final success = await service.renameItem(item, 'vol01_renamed.zip');
      expect(success, isTrue);

      final renamedFile = File('${tempDir.path}${Platform.pathSeparator}vol01_renamed.zip');
      expect(renamedFile.existsSync(), isTrue);
      expect(file.existsSync(), isFalse);
    });

    test('deleteItem removes file and folder recursively', () async {
      final file = File('${tempDir.path}${Platform.pathSeparator}sample.cbz');
      file.writeAsStringSync('content');

      final item = MediaItem(
        id: file.path,
        name: 'sample.cbz',
        isFolder: false,
      );

      final success = await service.deleteItem(item);
      expect(success, isTrue);
      expect(file.existsSync(), isFalse);
    });

    test('copyItem with duplicate naming generates "- 복사본" and "- 복사본 (2)"', () async {
      final file = File('${tempDir.path}${Platform.pathSeparator}onepiece.cbz');
      file.writeAsStringSync('dummy manga');

      final item = MediaItem(
        id: file.path,
        name: 'onepiece.cbz',
        isFolder: false,
      );

      // First copy into same folder -> onepiece - 복사본.cbz
      final success1 = await service.copyItem(item, tempDir.path);
      expect(success1, isTrue);

      final copy1 = File('${tempDir.path}${Platform.pathSeparator}onepiece - 복사본.cbz');
      expect(copy1.existsSync(), isTrue);

      // Second copy into same folder -> onepiece - 복사본 (2).cbz
      final success2 = await service.copyItem(item, tempDir.path);
      expect(success2, isTrue);

      final copy2 = File('${tempDir.path}${Platform.pathSeparator}onepiece - 복사본 (2).cbz');
      expect(copy2.existsSync(), isTrue);
    });

    test('moveItem moves file to destination folder', () async {
      final subDir = Directory('${tempDir.path}${Platform.pathSeparator}TargetFolder')..createSync();
      final file = File('${tempDir.path}${Platform.pathSeparator}naruto.zip');
      file.writeAsStringSync('naruto chapter');

      final item = MediaItem(
        id: file.path,
        name: 'naruto.zip',
        isFolder: false,
      );

      final success = await service.moveItem(item, subDir.path);
      expect(success, isTrue);

      final movedFile = File('${subDir.path}${Platform.pathSeparator}naruto.zip');
      expect(movedFile.existsSync(), isTrue);
      expect(file.existsSync(), isFalse);
    });
  });
}
