import '../comic_translator_engine.dart';
import 'platform_translator_factory_stub.dart'
    if (dart.library.io) 'platform_translator_factory_io.dart';

/// 플랫폼 분기(Conditional Import)를 통해 안전한 기본 온디바이스 번역 엔진을 생성합니다.
ComicTranslatorEngine createDefaultOnDeviceEngine() =>
    createPlatformOnDeviceEngine();

/// 플랫폼 분기(Conditional Import)를 통해 온라인 무료 구글 하이브리드 번역 엔진을 생성합니다.
ComicTranslatorEngine createDefaultFreeGoogleEngine({
  ComicTranslatorEngine? onDeviceEngine,
  void Function(String message)? onNotice,
}) =>
    createPlatformFreeGoogleEngine(
      onDeviceEngine: onDeviceEngine,
      onNotice: onNotice,
    );
