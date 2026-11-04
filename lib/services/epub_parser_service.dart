import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:xml/xml.dart';
import '../models/ebook_content.dart';
import '../utils/text_encoding_utils.dart';

class EpubParserService {
  /// EPUB 바이트에서 표지(Cover) 이미지만 빠르게 추출합니다.
  static Uint8List? extractCoverThumbnail(Uint8List epubBytes) {
    try {
      final archive = ZipDecoder().decodeBytes(epubBytes);
      final Map<String, ArchiveFile> fileMap = {};
      for (final f in archive.files) {
        if (f.isFile) {
          fileMap[_normalizePath(f.name)] = f;
        }
      }

      // 1. OPF 경로 탐색
      final opfPath = _findOpfPath(fileMap);
      if (opfPath != null && fileMap.containsKey(opfPath)) {
        final opfDir = _getDir(opfPath);
        final opfXmlStr = utf8.decode(fileMap[opfPath]!.content, allowMalformed: true);
        final opfDoc = XmlDocument.parse(opfXmlStr);

        // manifest에서 properties="cover-image" 또는 id="cover" 탐색
        final items = opfDoc.findAllElements('item');
        String? coverId;
        for (final meta in opfDoc.findAllElements('meta')) {
          if (meta.getAttribute('name')?.toLowerCase() == 'cover') {
            coverId = meta.getAttribute('content');
            break;
          }
        }

        for (final item in items) {
          final id = item.getAttribute('id') ?? '';
          final props = item.getAttribute('properties') ?? '';
          final href = item.getAttribute('href') ?? '';
          final mediaType = item.getAttribute('media-type') ?? '';

          if (mediaType.startsWith('image/') &&
              (props.contains('cover-image') ||
                  (coverId != null && id == coverId) ||
                  id.toLowerCase().contains('cover') ||
                  href.toLowerCase().contains('cover'))) {
            final fullPath = _resolveRelativePath(opfDir, Uri.decodeFull(href));
            if (fileMap.containsKey(fullPath)) {
              return fileMap[fullPath]!.content;
            }
          }
        }
      }

      // 2. 폴백: 아카이브 내 첫 번째 이미지 파일 반환
      for (final entry in fileMap.entries) {
        final lower = entry.key.toLowerCase();
        if (lower.endsWith('.jpg') ||
            lower.endsWith('.jpeg') ||
            lower.endsWith('.png') ||
            lower.endsWith('.webp')) {
          return entry.value.content;
        }
      }
    } catch (_) {}
    return null;
  }

  /// EPUB 바이트 전체를 파싱하여 목차, 본문 블록, 삽화 이미지 맵을 포함한 EbookDocument를 반환합니다.
  static Future<EbookDocument> parseEpubBytes({
    required Uint8List bytes,
    required String fallbackTitle,
  }) async {
    final archive = ZipDecoder().decodeBytes(bytes);
    final Map<String, ArchiveFile> fileMap = {};
    final Map<String, Uint8List> imageMap = {};

    for (final f in archive.files) {
      if (!f.isFile) continue;
      final norm = _normalizePath(f.name);
      fileMap[norm] = f;

      final lower = norm.toLowerCase();
      if (lower.endsWith('.jpg') ||
          lower.endsWith('.jpeg') ||
          lower.endsWith('.png') ||
          lower.endsWith('.webp') ||
          lower.endsWith('.gif') ||
          lower.endsWith('.bmp')) {
        imageMap[norm] = f.content;
      }
    }

    final opfPath = _findOpfPath(fileMap);
    if (opfPath == null || !fileMap.containsKey(opfPath)) {
      throw Exception('유효한 EPUB 구조(OPF 패키지 문서)를 찾을 수 없습니다.');
    }

    final opfDir = _getDir(opfPath);
    final opfDecoded = await TextEncodingUtils.decodeBytes(fileMap[opfPath]!.content);
    final opfDoc = XmlDocument.parse(opfDecoded.text);

    // 1. 메타데이터 (제목, 저자) 추출
    String title = fallbackTitle;
    String? author;
    for (final el in opfDoc.descendants.whereType<XmlElement>()) {
      final local = el.name.local.toLowerCase();
      if (local == 'title' && el.innerText.trim().isNotEmpty) {
        title = el.innerText.trim();
      } else if (local == 'creator' && el.innerText.trim().isNotEmpty) {
        author = el.innerText.trim();
      }
    }

    // 2. Manifest 매핑 (id -> href, media-type)
    final Map<String, String> idToPath = {};
    final Map<String, String> idToMediaType = {};
    String? ncxPath;
    String? navPath;

    for (final item in opfDoc.descendants.whereType<XmlElement>()) {
      if (item.name.local.toLowerCase() != 'item') continue;
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      final mediaType = item.getAttribute('media-type') ?? '';
      final props = item.getAttribute('properties') ?? '';

      if (id != null && href != null) {
        final decodedHref = _safeDecodeUri(href);
        final resolved = _resolveRelativePath(opfDir, decodedHref);
        idToPath[id] = resolved;
        idToMediaType[id] = mediaType;

        if (mediaType.contains('ncx') || resolved.toLowerCase().endsWith('.ncx')) {
          ncxPath = resolved;
        }
        if (props.contains('nav')) {
          navPath = resolved;
        }
      }
    }

    // 3. NCX / NAV 목차(TOC) 타이틀 매핑 (파일 경로 -> 목차 제목)
    final Map<String, String> pathToTocTitle = {};
    if (ncxPath != null && fileMap.containsKey(ncxPath)) {
      _parseNcxToc(fileMap[ncxPath]!, _getDir(ncxPath), pathToTocTitle);
    }
    if (navPath != null && fileMap.containsKey(navPath)) {
      _parseNavToc(fileMap[navPath]!, _getDir(navPath), pathToTocTitle);
    }

    // 4. Spine 순서대로 챕터 파싱
    final List<String> spinePaths = [];
    for (final itemref in opfDoc.descendants.whereType<XmlElement>()) {
      if (itemref.name.local.toLowerCase() != 'itemref') continue;
      final idref = itemref.getAttribute('idref');
      if (idref != null && idToPath.containsKey(idref)) {
        final p = idToPath[idref]!;
        if (!spinePaths.contains(p)) {
          spinePaths.add(p);
        }
      }
    }

    // 만약 spine이 비어있다면 xhtml/html 파일들을 이름순으로 폴백
    if (spinePaths.isEmpty) {
      final htmlKeys = fileMap.keys
          .where((k) => k.toLowerCase().endsWith('.xhtml') || k.toLowerCase().endsWith('.html') || k.toLowerCase().endsWith('.htm'))
          .toList()
        ..sort();
      spinePaths.addAll(htmlKeys);
    }

    final List<EbookChapter> chapters = [];
    final List<EbookBlock> allBlocks = [];
    int runningCharOffset = 0;

    for (int i = 0; i < spinePaths.length; i++) {
      final chapterPath = spinePaths[i];
      final archiveFile = fileMap[chapterPath];
      if (archiveFile == null) continue;

      final chapterDir = _getDir(chapterPath);
      final decodedHtml = await TextEncodingUtils.decodeBytes(archiveFile.content);

      final parsed = _parseXhtmlChapter(
        htmlContent: decodedHtml.text,
        chapterDir: chapterDir,
        availableImages: imageMap,
        startCharOffset: runningCharOffset,
      );

      if (parsed.blocks.isEmpty) continue;

      runningCharOffset = parsed.endCharOffset;

      // 목차 제목 결정: 1순위 NCX/NAV 매핑, 2순위 본문 내 첫 번째 헤딩/title 태그, 3순위 '제 N 장'
      String chapterTitle = pathToTocTitle[chapterPath] ??
          parsed.extractedTitle ??
          '챕터 ${chapters.length + 1}';

      chapters.add(
        EbookChapter(
          index: chapters.length,
          title: chapterTitle,
          blocks: parsed.blocks,
          startCharOffset: parsed.blocks.first.startCharOffset,
          endCharOffset: parsed.blocks.last.endCharOffset,
        ),
      );
      allBlocks.addAll(parsed.blocks);
    }

    if (allBlocks.isEmpty) {
      allBlocks.add(
        const EbookBlock(
          type: EbookBlockType.paragraph,
          text: '(EPUB 본문 텍스트를 추출할 수 없습니다.)',
          startCharOffset: 0,
          endCharOffset: 1,
        ),
      );
      chapters.add(
        EbookChapter(
          index: 0,
          title: title,
          blocks: allBlocks,
          startCharOffset: 0,
          endCharOffset: 1,
        ),
      );
      runningCharOffset = 1;
    }

    final coverBytes = extractCoverThumbnail(bytes);

    return EbookDocument(
      title: title,
      author: author,
      encoding: 'EPUB',
      chapters: chapters,
      allBlocks: allBlocks,
      images: imageMap,
      coverBytes: coverBytes,
      totalCharacters: runningCharOffset > 0 ? runningCharOffset : 1,
    );
  }

  static String? _findOpfPath(Map<String, ArchiveFile> fileMap) {
    const containerKey = 'META-INF/container.xml';
    for (final entry in fileMap.entries) {
      if (entry.key.toLowerCase() == containerKey.toLowerCase()) {
        try {
          final xmlStr = utf8.decode(entry.value.content, allowMalformed: true);
          final doc = XmlDocument.parse(xmlStr);
          for (final rf in doc.descendants.whereType<XmlElement>()) {
            if (rf.name.local.toLowerCase() == 'rootfile') {
              final fullPath = rf.getAttribute('full-path');
              if (fullPath != null && fullPath.isNotEmpty) {
                return _normalizePath(fullPath);
              }
            }
          }
        } catch (_) {}
      }
    }

    for (final key in fileMap.keys) {
      if (key.toLowerCase().endsWith('.opf')) {
        return key;
      }
    }
    return null;
  }

  static void _parseNcxToc(
    ArchiveFile ncxFile,
    String ncxDir,
    Map<String, String> outMap,
  ) {
    try {
      final xmlStr = utf8.decode(ncxFile.content, allowMalformed: true);
      final doc = XmlDocument.parse(xmlStr);
      for (final navPoint in doc.descendants.whereType<XmlElement>()) {
        if (navPoint.name.local.toLowerCase() != 'navpoint') continue;
        String? label;
        String? src;
        for (final child in navPoint.descendants.whereType<XmlElement>()) {
          final local = child.name.local.toLowerCase();
          if (local == 'text' && label == null && child.innerText.trim().isNotEmpty) {
            label = child.innerText.trim();
          } else if (local == 'content' && src == null) {
            src = child.getAttribute('src');
          }
        }
        if (label != null && src != null) {
          final cleanSrc = _safeDecodeUri(src.split('#').first);
          final resolved = _resolveRelativePath(ncxDir, cleanSrc);
          outMap.putIfAbsent(resolved, () => label!);
        }
      }
    } catch (_) {}
  }

  static void _parseNavToc(
    ArchiveFile navFile,
    String navDir,
    Map<String, String> outMap,
  ) {
    try {
      final xmlStr = utf8.decode(navFile.content, allowMalformed: true);
      final linkRegex = RegExp(
        r'<a\s+[^>]*href\s*=\s*["\x27]([^"\x27#]+)(?:#[^"\x27]*)?["\x27][^>]*>(.*?)</a>',
        caseSensitive: false,
        dotAll: true,
      );
      for (final m in linkRegex.allMatches(xmlStr)) {
        final rawHref = _safeDecodeUri(m.group(1) ?? '');
        final rawLabel = _stripHtmlTags(m.group(2) ?? '').trim();
        if (rawHref.isNotEmpty && rawLabel.isNotEmpty) {
          final resolved = _resolveRelativePath(navDir, rawHref);
          outMap.putIfAbsent(resolved, () => rawLabel);
        }
      }
    } catch (_) {}
  }

  static _ParsedChapterResult _parseXhtmlChapter({
    required String htmlContent,
    required String chapterDir,
    required Map<String, Uint8List> availableImages,
    required int startCharOffset,
  }) {
    String? extractedTitle;
    final titleMatch = RegExp(r'<title[^>]*>(.*?)</title>', caseSensitive: false, dotAll: true)
        .firstMatch(htmlContent);
    if (titleMatch != null) {
      final t = _decodeHtmlEntities(_stripHtmlTags(titleMatch.group(1) ?? '')).trim();
      if (t.isNotEmpty && t.toLowerCase() != 'untitled') {
        extractedTitle = t;
      }
    }

    // body 내부만 추출 (없으면 전체 사용)
    String body = htmlContent;
    final bodyMatch = RegExp(r'<body[^>]*>(.*)</body>', caseSensitive: false, dotAll: true)
        .firstMatch(htmlContent);
    if (bodyMatch != null) {
      body = bodyMatch.group(1)!;
    }

    // script, style 태그 제거
    body = body
        .replaceAll(RegExp(r'<script[^>]*>.*?</script>', caseSensitive: false, dotAll: true), '')
        .replaceAll(RegExp(r'<style[^>]*>.*?</style>', caseSensitive: false, dotAll: true), '');

    // 루비 태그(<rt>)는 괄호 병기로 자연스럽게 변환
    body = body
        .replaceAll(RegExp(r'<rp[^>]*>.*?</rp>', caseSensitive: false, dotAll: true), '')
        .replaceAllMapped(
          RegExp(r'<rt[^>]*>(.*?)</rt>', caseSensitive: false, dotAll: true),
          (m) => '(${_stripHtmlTags(m.group(1) ?? '')})',
        );

    // 이미지 태그(<img ... src="..."> 또는 <image ... xlink:href="...">)를 특수 마커로 치환하여 순서 보존
    body = body.replaceAllMapped(
      RegExp(r'<(?:img|image)\b[^>]*(?:src|href)\s*=\s*["\x27]([^"\x27]+)["\x27][^>]*/?>', caseSensitive: false),
      (m) => '\n___EPUB_IMG:::${m.group(1)}:::\n',
    );

    // 헤딩 태그(<h1> ~ <h6>)를 마커로 치환
    body = body.replaceAllMapped(
      RegExp(r'<h([1-6])[^>]*>(.*?)</h\1>', caseSensitive: false, dotAll: true),
      (m) => '\n___EPUB_HEADING_${m.group(1)}:::${_stripHtmlTags(m.group(2) ?? '')}:::\n',
    );

    // 수평선(<hr>) 치환
    body = body.replaceAll(RegExp(r'<hr\b[^>]*/?>', caseSensitive: false), '\n___EPUB_HR___\n');

    // 블록 태그 경계를 개행으로 변환
    body = body
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</(?:p|div|li|blockquote|section|article|tr)>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<(?:p|div|li|blockquote|section|article)\b[^>]*>', caseSensitive: false), '\n');

    // 남은 모든 HTML 태그 제거 및 엔티티 복원
    final plainText = _decodeHtmlEntities(_stripHtmlTags(body));
    final lines = plainText.split('\n');

    final List<EbookBlock> blocks = [];
    int currentOffset = startCharOffset;

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      if (line.startsWith('___EPUB_IMG:::') && line.endsWith(':::')) {
        final rawSrc = line.substring('___EPUB_IMG:::'.length, line.length - 3).trim();
        final decodedSrc = _safeDecodeUri(rawSrc);
        final resolvedKey = _findMatchingImageKey(chapterDir, decodedSrc, availableImages);
        if (resolvedKey != null) {
          blocks.add(
            EbookBlock(
              type: EbookBlockType.image,
              text: '[삽화]',
              imageKey: resolvedKey,
              startCharOffset: currentOffset,
              endCharOffset: currentOffset + 1,
            ),
          );
          currentOffset += 1;
        }
        continue;
      }

      final headingMatch = RegExp(r'^___EPUB_HEADING_([1-6]):::(.*):::$').firstMatch(line);
      if (headingMatch != null) {
        final level = int.tryParse(headingMatch.group(1)!) ?? 2;
        final hText = headingMatch.group(2)!.trim();
        if (hText.isNotEmpty) {
          extractedTitle ??= hText;
          final end = currentOffset + hText.length;
          blocks.add(
            EbookBlock(
              type: EbookBlockType.heading,
              text: hText,
              headingLevel: level,
              startCharOffset: currentOffset,
              endCharOffset: end,
            ),
          );
          currentOffset = end + 1;
        }
        continue;
      }

      if (line == '___EPUB_HR___') {
        blocks.add(
          EbookBlock(
            type: EbookBlockType.divider,
            text: '***',
            startCharOffset: currentOffset,
            endCharOffset: currentOffset + 1,
          ),
        );
        currentOffset += 1;
        continue;
      }

      final end = currentOffset + line.length;
      blocks.add(
        EbookBlock(
          type: EbookBlockType.paragraph,
          text: line,
          startCharOffset: currentOffset,
          endCharOffset: end,
        ),
      );
      currentOffset = end + 1;
    }

    return _ParsedChapterResult(
      blocks: blocks,
      extractedTitle: extractedTitle,
      endCharOffset: currentOffset,
    );
  }

  static String? _findMatchingImageKey(
    String chapterDir,
    String rawSrc,
    Map<String, Uint8List> availableImages,
  ) {
    final resolved = _resolveRelativePath(chapterDir, rawSrc);
    if (availableImages.containsKey(resolved)) {
      return resolved;
    }
    // 대소문자 무시 또는 파일명 기준 매칭 폴백
    final lowerResolved = resolved.toLowerCase();
    final baseName = lowerResolved.split('/').last;
    for (final k in availableImages.keys) {
      final lk = k.toLowerCase();
      if (lk == lowerResolved || lk.endsWith('/$baseName') || lk == baseName) {
        return k;
      }
    }
    return null;
  }

  static String _stripHtmlTags(String input) {
    return input.replaceAll(RegExp(r'<[^>]*>'), '');
  }

  static String _decodeHtmlEntities(String input) {
    return input
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&ldquo;', '“')
        .replaceAll('&rdquo;', '”')
        .replaceAll('&lsquo;', '‘')
        .replaceAll('&rsquo;', '’')
        .replaceAll('&hellip;', '…')
        .replaceAll('&mdash;', '—')
        .replaceAll('&ndash;', '–')
        .replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
          final code = int.tryParse(m.group(1)!);
          return code != null ? String.fromCharCode(code) : m.group(0)!;
        })
        .replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
          final code = int.tryParse(m.group(1)!, radix: 16);
          return code != null ? String.fromCharCode(code) : m.group(0)!;
        });
  }

  static String _safeDecodeUri(String uri) {
    try {
      return Uri.decodeFull(uri);
    } catch (_) {
      return uri;
    }
  }

  static String _normalizePath(String path) {
    final parts = path.replaceAll('\\', '/').split('/');
    final stack = <String>[];
    for (final part in parts) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (stack.isNotEmpty) stack.removeLast();
      } else {
        stack.add(part);
      }
    }
    return stack.join('/');
  }

  static String _getDir(String filePath) {
    final idx = filePath.lastIndexOf('/');
    if (idx == -1) return '';
    return filePath.substring(0, idx);
  }

  static String _resolveRelativePath(String baseDir, String relativePath) {
    if (relativePath.startsWith('/')) {
      return _normalizePath(relativePath.substring(1));
    }
    if (baseDir.isEmpty) {
      return _normalizePath(relativePath);
    }
    return _normalizePath('$baseDir/$relativePath');
  }
}

class _ParsedChapterResult {
  final List<EbookBlock> blocks;
  final String? extractedTitle;
  final int endCharOffset;

  const _ParsedChapterResult({
    required this.blocks,
    this.extractedTitle,
    required this.endCharOffset,
  });
}
