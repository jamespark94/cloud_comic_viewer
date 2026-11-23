import '../viewer_settings.dart';
import 'translated_bubble.dart';

/// 페이지 번역 처리 상태
enum PageTranslationStatus {
  idle,
  translating,
  completed,
  failed,
}

/// 단일 만화 페이지의 번역 결과 및 캐시 직렬화 모델
class PageTranslationResult {
  final String bookId;
  final int pageIndex;
  final ComicSourceLanguage sourceLanguage;
  final ComicTranslationEngineType engineType;
  final String engineId;
  final List<TranslatedBubble> bubbles;
  final PageTranslationStatus status;
  final DateTime createdAt;
  final String? errorMessage;

  const PageTranslationResult({
    required this.bookId,
    required this.pageIndex,
    required this.sourceLanguage,
    this.engineType = ComicTranslationEngineType.onDevice,
    required this.engineId,
    required this.bubbles,
    this.status = PageTranslationStatus.completed,
    required this.createdAt,
    this.errorMessage,
  });

  Map<String, dynamic> toJson() => {
        'bookId': bookId,
        'pageIndex': pageIndex,
        'sourceLanguage': sourceLanguage.name,
        'engineType': engineType.name,
        'engineId': engineId,
        'bubbles': bubbles.map((b) => b.toJson()).toList(),
        'status': status.name,
        'createdAt': createdAt.toIso8601String(),
        if (errorMessage != null) 'errorMessage': errorMessage,
      };

  factory PageTranslationResult.fromJson(Map<String, dynamic> json) {
    final rawBubbles = json['bubbles'] as List<dynamic>? ?? const [];
    return PageTranslationResult(
      bookId: json['bookId'] as String? ?? '',
      pageIndex: (json['pageIndex'] as num?)?.toInt() ?? 0,
      sourceLanguage: ComicSourceLanguage.values.firstWhere(
        (e) => e.name == json['sourceLanguage'],
        orElse: () => ComicSourceLanguage.auto,
      ),
      engineType: ComicTranslationEngineType.values.firstWhere(
        (e) => e.name == json['engineType'],
        orElse: () => ComicTranslationEngineType.onDevice,
      ),
      engineId: json['engineId'] as String? ?? 'unknown',
      bubbles: rawBubbles
          .whereType<Map<String, dynamic>>()
          .map(TranslatedBubble.fromJson)
          .toList(),
      status: PageTranslationStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => PageTranslationStatus.completed,
      ),
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      errorMessage: json['errorMessage'] as String?,
    );
  }
}
