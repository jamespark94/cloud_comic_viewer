import 'dart:typed_data';
import '../models/ebook_content.dart';
import '../utils/text_encoding_utils.dart';

class TxtParserService {
  /// 한국어/영어 소설에서 자주 사용되는 챕터/화/장 제목 정규식 패턴
  static final RegExp _chapterHeadingRegex = RegExp(
    r'^(?:\s*)(?:제\s*\d+\s*[장화편절부권회막]|Chapter\s+\d+|Episode\s+\d+|EP\.?\s*\d+|\[\s*\d+\s*\]|\d+\s*[장화편절회]\b|프롤로그|에필로그|서장|종장|외전|Prologue|Epilogue).*$',
    caseSensitive: false,
  );

  /// 바이트 배열로부터 TXT 전자책 문서를 파싱합니다.
  static Future<EbookDocument> parseTxtBytes({
    required Uint8List bytes,
    required String title,
    String? forceEncoding,
  }) async {
    final decoded = await TextEncodingUtils.decodeBytes(
      bytes,
      forceEncoding: forceEncoding,
    );

    final rawText = decoded.text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = rawText.split('\n');

    final List<EbookBlock> allBlocks = [];
    final List<_ChapterMarker> markers = [];

    int runningCharOffset = 0;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trimRight();
      if (line.trim().isEmpty) {
        continue;
      }

      final trimmed = line.trim();
      final isHeading = trimmed.length <= 65 && _chapterHeadingRegex.hasMatch(trimmed);

      final startOffset = runningCharOffset;
      final endOffset = startOffset + trimmed.length;
      runningCharOffset = endOffset + 1;

      if (isHeading) {
        markers.add(
          _ChapterMarker(
            title: trimmed,
            blockIndex: allBlocks.length,
            startCharOffset: startOffset,
          ),
        );
        allBlocks.add(
          EbookBlock(
            type: EbookBlockType.heading,
            text: trimmed,
            headingLevel: 2,
            startCharOffset: startOffset,
            endCharOffset: endOffset,
          ),
        );
      } else {
        allBlocks.add(
          EbookBlock(
            type: EbookBlockType.paragraph,
            text: trimmed,
            startCharOffset: startOffset,
            endCharOffset: endOffset,
          ),
        );
      }
    }

    // 빈 파일 방어 처리
    if (allBlocks.isEmpty) {
      allBlocks.add(
        const EbookBlock(
          type: EbookBlockType.paragraph,
          text: '(내용이 없는 빈 텍스트 파일입니다.)',
          startCharOffset: 0,
          endCharOffset: 1,
        ),
      );
      runningCharOffset = 1;
    }

    final List<EbookChapter> chapters = [];

    if (markers.isEmpty) {
      // 정규식 목차가 하나도 감지되지 않은 경우: 일정 분량(약 250문단) 단위로 가상 목차 자동 분할
      const int chunkBlocks = 250;
      int chapterIdx = 0;
      for (int start = 0; start < allBlocks.length; start += chunkBlocks) {
        final end = (start + chunkBlocks < allBlocks.length) ? start + chunkBlocks : allBlocks.length;
        final slice = allBlocks.sublist(start, end);
        chapters.add(
          EbookChapter(
            index: chapterIdx,
            title: allBlocks.length <= chunkBlocks ? '본문 전체' : '구간 ${chapterIdx + 1}',
            blocks: slice,
            startCharOffset: slice.first.startCharOffset,
            endCharOffset: slice.last.endCharOffset,
          ),
        );
        chapterIdx++;
      }
    } else {
      // 첫 번째 챕터 마커 이전에 서문/도입부 문단이 있는 경우
      if (markers.first.blockIndex > 0) {
        final introSlice = allBlocks.sublist(0, markers.first.blockIndex);
        chapters.add(
          EbookChapter(
            index: 0,
            title: '서문 / 도입부',
            blocks: introSlice,
            startCharOffset: introSlice.first.startCharOffset,
            endCharOffset: introSlice.last.endCharOffset,
          ),
        );
      }

      for (int m = 0; m < markers.length; m++) {
        final startBlockIdx = markers[m].blockIndex;
        final endBlockIdx = (m + 1 < markers.length) ? markers[m + 1].blockIndex : allBlocks.length;
        final slice = allBlocks.sublist(startBlockIdx, endBlockIdx);
        if (slice.isEmpty) continue;
        chapters.add(
          EbookChapter(
            index: chapters.length,
            title: markers[m].title,
            blocks: slice,
            startCharOffset: slice.first.startCharOffset,
            endCharOffset: slice.last.endCharOffset,
          ),
        );
      }
    }

    return EbookDocument(
      title: title,
      encoding: decoded.encoding,
      chapters: chapters,
      allBlocks: allBlocks,
      totalCharacters: runningCharOffset > 0 ? runningCharOffset : 1,
    );
  }
}

class _ChapterMarker {
  final String title;
  final int blockIndex;
  final int startCharOffset;

  const _ChapterMarker({
    required this.title,
    required this.blockIndex,
    required this.startCharOffset,
  });
}
