import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class ThumbnailService {
  static Directory? _thumbnailDir;

  static Future<Directory> _getThumbnailDirectory() async {
    if (_thumbnailDir != null && _thumbnailDir!.existsSync()) {
      return _thumbnailDir!;
    }
    final appDir = await getApplicationSupportDirectory();
    final dir = Directory(p.join(appDir.path, 'thumbnails'));
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    _thumbnailDir = dir;
    return dir;
  }

  static String _getFileName(String comicId) {
    final hash = md5.convert(utf8.encode(comicId)).toString();
    return '$hash.jpg';
  }

  /// 특정 만화책의 저장된 표지 썸네일 경로를 반환합니다. (없으면 null)
  static Future<String?> getCoverThumbnailPath(String comicId) async {
    final dir = await _getThumbnailDirectory();
    final file = File(p.join(dir.path, _getFileName(comicId)));
    if (await file.exists()) {
      return file.path;
    }
    return null;
  }

  /// 만화책의 첫 페이지(표지) 이미지를 썸네일로 디스크에 저장하고 파일 경로를 반환합니다.
  static Future<String?> saveCoverThumbnail(String comicId, Uint8List imageBytes) async {
    try {
      final dir = await _getThumbnailDirectory();
      final file = File(p.join(dir.path, _getFileName(comicId)));
      if (await file.exists()) {
        return file.path;
      }
      await file.writeAsBytes(imageBytes);
      return file.path;
    } catch (_) {
      return null;
    }
  }
}
