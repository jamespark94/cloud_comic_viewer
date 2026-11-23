import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../../models/ai_translation/page_translation_result.dart';
import '../../models/viewer_settings.dart';

/// 책 ID + 페이지 인덱스 + 원본 언어 기준 2계층 번역 결과 캐시
/// - L1: 메모리 LRU 캐시 (최대 100페이지)
/// - L2: 로컬 임시 디렉토리 JSON 영속 캐시 (앞뒤 페이지 이동 및 재열람 시 재번역 0회)
class ComicTranslationCache {
  final int maxMemoryEntries;
  final Future<Directory> Function()? cacheDirProvider;

  final LinkedHashMap<String, PageTranslationResult> _memoryCache =
      LinkedHashMap<String, PageTranslationResult>();

  ComicTranslationCache({
    this.maxMemoryEntries = 100,
    this.cacheDirProvider,
  });

  static String buildKey(
    String bookId,
    int pageIndex,
    ComicSourceLanguage sourceLanguage, {
    ComicTranslationEngineType engineType = ComicTranslationEngineType.onDevice,
  }) =>
      '$bookId::$pageIndex::${sourceLanguage.name}::${engineType.name}';

  /// L1 메모리 캐시에서 동기식으로 즉시 조회합니다 (UI 렌더링 0ms).
  PageTranslationResult? getMemory(
    String bookId,
    int pageIndex,
    ComicSourceLanguage sourceLanguage, {
    ComicTranslationEngineType engineType = ComicTranslationEngineType.onDevice,
  }) {
    final key = buildKey(
      bookId,
      pageIndex,
      sourceLanguage,
      engineType: engineType,
    );
    final hit = _memoryCache.remove(key);
    if (hit != null) {
      _memoryCache[key] = hit;
    }
    return hit;
  }

  /// L1 메모리 + L2 디스크 캐시 순으로 조회합니다.
  Future<PageTranslationResult?> get(
    String bookId,
    int pageIndex,
    ComicSourceLanguage sourceLanguage, {
    ComicTranslationEngineType engineType = ComicTranslationEngineType.onDevice,
  }) async {
    final memHit = getMemory(
      bookId,
      pageIndex,
      sourceLanguage,
      engineType: engineType,
    );
    if (memHit != null) return memHit;

    try {
      final file = await _getCacheFile(
        bookId,
        pageIndex,
        sourceLanguage,
        engineType: engineType,
      );
      if (await file.exists()) {
        final raw = await file.readAsString();
        if (raw.isNotEmpty) {
          final parsed = PageTranslationResult.fromJson(
            jsonDecode(raw) as Map<String, dynamic>,
          );
          _putMemory(parsed);
          return parsed;
        }
      }
    } catch (_) {}
    return null;
  }

  /// 번역 결과를 L1 메모리와 L2 디스크 캐시에 모두 저장합니다.
  Future<void> put(PageTranslationResult result) async {
    _putMemory(result);
    try {
      final file = await _getCacheFile(
        result.bookId,
        result.pageIndex,
        result.sourceLanguage,
        engineType: result.engineType,
      );
      await file.writeAsString(jsonEncode(result.toJson()), flush: false);
    } catch (_) {}
  }

  void _putMemory(PageTranslationResult result) {
    final key = buildKey(
      result.bookId,
      result.pageIndex,
      result.sourceLanguage,
      engineType: result.engineType,
    );
    _memoryCache.remove(key);
    while (_memoryCache.length >= maxMemoryEntries) {
      _memoryCache.remove(_memoryCache.keys.first);
    }
    _memoryCache[key] = result;
  }

  Future<Directory> _resolveCacheDir() async {
    final baseDir = cacheDirProvider != null
        ? await cacheDirProvider!()
        : await getTemporaryDirectory();
    final subDir = Directory(p.join(baseDir.path, 'comic_translations'));
    if (!await subDir.exists()) {
      await subDir.create(recursive: true);
    }
    return subDir;
  }

  Future<File> _getCacheFile(
    String bookId,
    int pageIndex,
    ComicSourceLanguage sourceLanguage, {
    ComicTranslationEngineType engineType = ComicTranslationEngineType.onDevice,
  }) async {
    final dir = await _resolveCacheDir();
    final bookHash = md5.convert(utf8.encode(bookId)).toString();
    final fileName =
        '${bookHash}_p${pageIndex}_${sourceLanguage.name}_${engineType.name}.json';
    return File(p.join(dir.path, fileName));
  }

  void clearMemory() => _memoryCache.clear();

  Future<void> clearAll() async {
    _memoryCache.clear();
    try {
      final dir = await _resolveCacheDir();
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {}
  }
}
