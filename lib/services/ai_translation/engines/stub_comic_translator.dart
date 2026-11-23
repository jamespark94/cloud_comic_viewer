import '../../../models/ai_translation/translated_bubble.dart';
import '../../../models/viewer_settings.dart';
import '../comic_translator_engine.dart';

/// Windows 데스크톱 및 미지원 플랫폼에서 컴파일/런타임 에러 없이
/// 안전하게 비활성화되는 Stub 엔진
class StubComicTranslator implements ComicTranslatorEngine {
  @override
  final String? unsupportedReason;

  StubComicTranslator({this.unsupportedReason});

  @override
  String get engineId => 'stub_unsupported';

  @override
  String get displayName => '미지원 플랫폼 안전 스텁';

  @override
  bool get isSupported => false;

  @override
  Future<void> initialize({required ComicSourceLanguage sourceLanguage}) async {}

  @override
  Future<List<TranslatedBubble>> translatePage(
    ComicPageTranslationRequest request,
  ) async {
    return const [];
  }

  @override
  Future<void> dispose() async {}
}
