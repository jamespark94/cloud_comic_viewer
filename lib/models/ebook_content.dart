import 'dart:typed_data';

/// 전자책(TXT / EPUB / PDF) 내 책갈피(Bookmark) 모델
class EbookBookmark {
  final String id;
  final int chapterIndex;
  final String chapterTitle;
  final int charOffset; // TXT/EPUB 내 문자 오프셋 (PDF의 경우 페이지 인덱스)
  final String snippet; // 미리보기 문장
  final String? note;   // 사용자 메모
  final DateTime createdAt;

  EbookBookmark({
    required this.id,
    required this.chapterIndex,
    required this.chapterTitle,
    required this.charOffset,
    required this.snippet,
    this.note,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'chapterIndex': chapterIndex,
        'chapterTitle': chapterTitle,
        'charOffset': charOffset,
        'snippet': snippet,
        if (note != null) 'note': note,
        'createdAt': createdAt.toIso8601String(),
      };

  factory EbookBookmark.fromJson(Map<String, dynamic> json) => EbookBookmark(
        id: json['id'] as String? ?? '${DateTime.now().millisecondsSinceEpoch}',
        chapterIndex: json['chapterIndex'] as int? ?? 0,
        chapterTitle: json['chapterTitle'] as String? ?? '',
        charOffset: json['charOffset'] as int? ?? 0,
        snippet: json['snippet'] as String? ?? '',
        note: json['note'] as String?,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
      );
}

/// 전자책 본문 내 개별 문단 또는 이미지 블록
enum EbookBlockType {
  heading,
  paragraph,
  image,
  divider,
}

class EbookBlock {
  final EbookBlockType type;
  final String text;
  final int headingLevel; // 1 ~ 6 (heading인 경우)
  final String? imageKey; // EPUB 내장 이미지 키 (image인 경우)
  final int startCharOffset; // 문서 전체 기준 시작 글자 오프셋
  final int endCharOffset;   // 문서 전체 기준 끝 글자 오프셋

  const EbookBlock({
    required this.type,
    this.text = '',
    this.headingLevel = 0,
    this.imageKey,
    required this.startCharOffset,
    required this.endCharOffset,
  });

  int get charLength => (endCharOffset - startCharOffset).clamp(0, 100000000);
}

/// 전자책의 단일 챕터(목차 단위)
class EbookChapter {
  final int index;
  final String title;
  final List<EbookBlock> blocks;
  final int startCharOffset; // 문서 전체 기준 시작 글자 오프셋
  final int endCharOffset;   // 문서 전체 기준 종료 글자 오프셋

  const EbookChapter({
    required this.index,
    required this.title,
    required this.blocks,
    required this.startCharOffset,
    required this.endCharOffset,
  });
}

/// 파싱 완료된 TXT 또는 EPUB 문서 전체 구조체
class EbookDocument {
  final String title;
  final String? author;
  final String encoding; // 예: 'UTF-8', 'CP949', 'EUC-KR', 'EPUB'
  final List<EbookChapter> chapters;
  final List<EbookBlock> allBlocks;
  final Map<String, Uint8List> images; // EPUB 내장 삽화/표지 바이트 맵
  final Uint8List? coverBytes;
  final int totalCharacters;

  const EbookDocument({
    required this.title,
    this.author,
    required this.encoding,
    required this.chapters,
    required this.allBlocks,
    this.images = const {},
    this.coverBytes,
    required this.totalCharacters,
  });
}

/// 본문 내 키워드 검색 결과 항목
class EbookSearchResult {
  final int chapterIndex;
  final String chapterTitle;
  final int blockIndex;
  final int charOffset;
  final String snippet;

  const EbookSearchResult({
    required this.chapterIndex,
    required this.chapterTitle,
    required this.blockIndex,
    required this.charOffset,
    required this.snippet,
  });
}
