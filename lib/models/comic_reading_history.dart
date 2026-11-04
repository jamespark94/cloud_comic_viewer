import '../models/cloud_account.dart';
import 'ebook_content.dart';

class ComicReadingHistory {
  final String id; // itemId or unique path
  final String accountId;
  final String accountName;
  final CloudType cloudType;
  final String title;
  final String? parentFolderId;
  final int lastPage; // 0-based index (or virtual page / charOffset percentage)
  final int totalPages;
  final DateTime lastReadAt;
  final String? coverThumbnailUrl;

  // 전자책(TXT/EPUB/PDF) 통합 확장 필드 (하위 호환 100% 보장)
  final String? bookType;     // 'comic', 'txt', 'epub', 'pdf'
  final int? chapterIndex;    // 현재 챕터 번호
  final String? chapterTitle; // 현재 읽고 있는 챕터 제목
  final int? charOffset;      // TXT/EPUB 문서 내 문자 오프셋
  final List<EbookBookmark> bookmarks; // 등록된 책갈피 목록

  ComicReadingHistory({
    required this.id,
    required this.accountId,
    required this.accountName,
    required this.cloudType,
    required this.title,
    this.parentFolderId,
    required this.lastPage,
    required this.totalPages,
    required this.lastReadAt,
    this.coverThumbnailUrl,
    this.bookType,
    this.chapterIndex,
    this.chapterTitle,
    this.charOffset,
    this.bookmarks = const [],
  });

  double get progress => totalPages > 0 ? ((lastPage + 1) / totalPages).clamp(0.0, 1.0) : 0.0;
  int get progressPercent => (progress * 100).clamp(0, 100).round();

  /// 파일명 또는 bookType 필드를 기반으로 포맷 배지 문자열 반환
  String get badgeLabel {
    final t = (bookType ?? '').toLowerCase();
    final lowerTitle = title.toLowerCase();
    if (t == 'epub' || lowerTitle.endsWith('.epub')) return 'EPUB';
    if (t == 'txt' || lowerTitle.endsWith('.txt') || lowerTitle.endsWith('.md')) return 'TXT';
    if (t == 'pdf' || lowerTitle.endsWith('.pdf')) return 'PDF';
    return 'COMIC';
  }

  bool get isTextOrEpub {
    final b = badgeLabel;
    return b == 'TXT' || b == 'EPUB';
  }

  /// 진도 표시용 요약 텍스트 (예: "12 / 150p" 또는 "제3장 • 45%")
  String get progressSummaryText {
    if (isTextOrEpub) {
      if (chapterTitle != null && chapterTitle!.trim().isNotEmpty) {
        return '${chapterTitle!.trim()} ($progressPercent%)';
      }
      return '$progressPercent% 읽음';
    }
    return '${lastPage + 1} / ${totalPages}p';
  }

  ComicReadingHistory copyWith({
    String? id,
    String? accountId,
    String? accountName,
    CloudType? cloudType,
    String? title,
    String? parentFolderId,
    int? lastPage,
    int? totalPages,
    DateTime? lastReadAt,
    String? coverThumbnailUrl,
    String? bookType,
    int? chapterIndex,
    String? chapterTitle,
    int? charOffset,
    List<EbookBookmark>? bookmarks,
  }) {
    return ComicReadingHistory(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      accountName: accountName ?? this.accountName,
      cloudType: cloudType ?? this.cloudType,
      title: title ?? this.title,
      parentFolderId: parentFolderId ?? this.parentFolderId,
      lastPage: lastPage ?? this.lastPage,
      totalPages: totalPages ?? this.totalPages,
      lastReadAt: lastReadAt ?? this.lastReadAt,
      coverThumbnailUrl: coverThumbnailUrl ?? this.coverThumbnailUrl,
      bookType: bookType ?? this.bookType,
      chapterIndex: chapterIndex ?? this.chapterIndex,
      chapterTitle: chapterTitle ?? this.chapterTitle,
      charOffset: charOffset ?? this.charOffset,
      bookmarks: bookmarks ?? this.bookmarks,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'accountId': accountId,
        'accountName': accountName,
        'cloudType': cloudType.name,
        'title': title,
        'parentFolderId': parentFolderId,
        'lastPage': lastPage,
        'totalPages': totalPages,
        'lastReadAt': lastReadAt.toIso8601String(),
        'coverThumbnailUrl': coverThumbnailUrl,
        if (bookType != null) 'bookType': bookType,
        if (chapterIndex != null) 'chapterIndex': chapterIndex,
        if (chapterTitle != null) 'chapterTitle': chapterTitle,
        if (charOffset != null) 'charOffset': charOffset,
        if (bookmarks.isNotEmpty) 'bookmarks': bookmarks.map((b) => b.toJson()).toList(),
      };

  factory ComicReadingHistory.fromJson(Map<String, dynamic> json) {
    final rawBookmarks = json['bookmarks'] as List<dynamic>?;
    final parsedBookmarks = rawBookmarks != null
        ? rawBookmarks
            .whereType<Map<String, dynamic>>()
            .map(EbookBookmark.fromJson)
            .toList()
        : const <EbookBookmark>[];

    return ComicReadingHistory(
      id: json['id'] as String,
      accountId: json['accountId'] as String,
      accountName: json['accountName'] as String,
      cloudType: CloudType.values.firstWhere(
        (e) => e.name == json['cloudType'],
        orElse: () => CloudType.local,
      ),
      title: json['title'] as String,
      parentFolderId: json['parentFolderId'] as String?,
      lastPage: json['lastPage'] as int? ?? 0,
      totalPages: json['totalPages'] as int? ?? 1,
      lastReadAt: DateTime.tryParse(json['lastReadAt'] as String? ?? '') ?? DateTime.now(),
      coverThumbnailUrl: json['coverThumbnailUrl'] as String?,
      bookType: json['bookType'] as String?,
      chapterIndex: json['chapterIndex'] as int?,
      chapterTitle: json['chapterTitle'] as String?,
      charOffset: json['charOffset'] as int?,
      bookmarks: parsedBookmarks,
    );
  }
}
