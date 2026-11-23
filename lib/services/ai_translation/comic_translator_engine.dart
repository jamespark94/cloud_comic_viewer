import 'dart:typed_data';
import '../../models/ai_translation/translated_bubble.dart';
import '../../models/viewer_settings.dart';

/// 단일 만화 페이지 번역을 위한 엔진 입력 요청 모델
class ComicPageTranslationRequest {
  final String bookId;
  final int pageIndex;
  final Uint8List imageBytes;
  final int imageWidth;
  final int imageHeight;
  final ComicSourceLanguage sourceLanguage;
  final String targetLanguage;
  final bool isRightToLeftManga;

  const ComicPageTranslationRequest({
    required this.bookId,
    required this.pageIndex,
    required this.imageBytes,
    required this.imageWidth,
    required this.imageHeight,
    required this.sourceLanguage,
    this.targetLanguage = 'ko',
    this.isRightToLeftManga = true,
  });
}

/// Phase 1 (온디바이스 ML Kit) 및 Phase 2 (클라우드 멀티모달 비전 API)를
/// 무중단으로 교체·확장할 수 있는 Strategy Pattern 추상 엔진 인터페이스
abstract class ComicTranslatorEngine {
  String get engineId;
  String get displayName;

  /// 현재 OS 플랫폼에서 해당 엔진이 동작 가능한지 여부
  bool get isSupported;

  /// 미지원 플랫폼일 경우 사용자에게 안내할 사유 메시지
  String? get unsupportedReason => null;

  /// 언어 스크립트별 OCR 및 번역기 초기화 (Lazy Initialization)
  Future<void> initialize({required ComicSourceLanguage sourceLanguage});

  /// 단일 만화 페이지 이미지 바이트에서 말풍선 인식 + 병합 + 배경색 추정 + 한국어 번역 수행
  Future<List<TranslatedBubble>> translatePage(
    ComicPageTranslationRequest request,
  );

  /// 뷰어 종료 또는 번역 모드 OFF 전환 시 네이티브 리소스 즉시 해제
  Future<void> dispose();
}
