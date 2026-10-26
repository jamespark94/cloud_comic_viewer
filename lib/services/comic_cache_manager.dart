import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../models/media_item.dart';
import 'cloud_service_interface.dart';

class ComicCacheManager {
  static ComicCacheManager? _instance;
  static ComicCacheManager get instance => _instance ??= ComicCacheManager._();

  ComicCacheManager._();

  Future<Directory> _getCacheDirectory() async {
    final tempDir = await getTemporaryDirectory();
    final comicCacheDir = Directory(p.join(tempDir.path, 'comic_cache'));
    if (!await comicCacheDir.exists()) {
      await comicCacheDir.create(recursive: true);
    }
    return comicCacheDir;
  }

  String _getCacheKey(String accountId, MediaItem item) {
    final raw = '$accountId:${item.id}:${item.name}';
    final hash = md5.convert(raw.codeUnits).toString();
    return '${hash}_${item.name}';
  }

  /// 캐시된 파일이 있는지 확인하고 파일 경로를 반환합니다.
  Future<File?> getCachedFile(String accountId, MediaItem item) async {
    final dir = await _getCacheDirectory();
    final fileName = _getCacheKey(accountId, item);
    final file = File(p.join(dir.path, fileName));
    if (await file.exists()) {
      return file;
    }
    return null;
  }

  /// 클라우드 또는 로컬에서 만화책 바이트를 로드하거나 캐시합니다.
  Future<Uint8List> loadOrDownloadComicBytes(
    CloudService service,
    MediaItem item, {
    void Function(int received, int total)? onProgress,
  }) async {
    // 1. 이미 로컬 파일인 경우 바로 읽기
    if (service.account.id == 'local') {
      return await service.downloadBytes(item, onProgress: onProgress);
    }

    // 2. 캐시 디스크 확인
    final cached = await getCachedFile(service.account.id, item);
    if (cached != null && (await cached.length()) > 500) {
      final bytes = await cached.readAsBytes();
      if (onProgress != null) {
        onProgress(bytes.length, bytes.length);
      }
      return bytes;
    }

    // 3. 원격 클라우드에서 다운로드
    final bytes = await service.downloadBytes(item, onProgress: onProgress);

    // 4. 캐시에 비동기 저장
    try {
      final dir = await _getCacheDirectory();
      final fileName = _getCacheKey(service.account.id, item);
      final cacheFile = File(p.join(dir.path, fileName));
      await cacheFile.writeAsBytes(bytes);
    } catch (_) {}

    return bytes;
  }

  /// 캐시 디렉토리 전체 용량 확인
  Future<int> getCacheTotalSize() async {
    final dir = await _getCacheDirectory();
    int total = 0;
    try {
      final files = dir.listSync();
      for (final f in files) {
        if (f is File) {
          total += await f.length();
        }
      }
    } catch (_) {}
    return total;
  }

  /// 캐시 전체 비우기
  Future<void> clearCache() async {
    final dir = await _getCacheDirectory();
    try {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
        await dir.create(recursive: true);
      }
    } catch (_) {}
  }
}
