import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:archive/archive.dart';
import 'package:cloud_comic_viewer/models/cloud_account.dart';
import 'package:cloud_comic_viewer/models/media_item.dart';
import 'package:cloud_comic_viewer/services/local_disk_service.dart';
import 'package:cloud_comic_viewer/services/zip_stream_reader.dart';

void main() {
  test('ZipStreamReader parses entries and streams pages correctly', () async {
    // 1. 테스트 ZIP 파일 생성
    final archive = Archive();
    final img1 = Uint8List.fromList([10, 20, 30, 40, 50]);
    final img2 = Uint8List.fromList([60, 70, 80, 90, 100]);

    archive.addFile(ArchiveFile('page_01.jpg', img1.length, img1));
    archive.addFile(ArchiveFile('page_02.png', img2.length, img2));

    final zipData = ZipEncoder().encode(archive);

    final tempFile = File('${Directory.systemTemp.path}/test_stream_${DateTime.now().millisecondsSinceEpoch}.zip');
    await tempFile.writeAsBytes(zipData);

    try {
      final account = CloudAccount(
        id: 'local',
        name: 'Local',
        type: CloudType.local,
        email: '',
        accessToken: '',
      );
      final service = LocalDiskService(account);
      final item = MediaItem(
        id: tempFile.path,
        name: 'test.zip',
        isFolder: false,
        size: tempFile.lengthSync(),
      );

      final pages = await ZipStreamReader.extractPagesStreamed(
        service: service,
        item: item,
      );

      expect(pages.length, equals(2));
      expect(pages[0].name, equals('page_01.jpg'));
      expect(pages[1].name, equals('page_02.png'));

      // Lazy load bytes
      final b1 = await pages[0].getBytes();
      final b2 = await pages[1].getBytes();

      expect(b1, equals(img1));
      expect(b2, equals(img2));
    } finally {
      if (tempFile.existsSync()) {
        tempFile.deleteSync();
      }
    }
  });
}
