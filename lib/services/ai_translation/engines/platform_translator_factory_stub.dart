import '../comic_translator_engine.dart';
import 'stub_comic_translator.dart';

ComicTranslatorEngine createPlatformOnDeviceEngine() {
  return StubComicTranslator(
    unsupportedReason: '현재 플랫폼에서는 온디바이스 ML Kit 번역이 지원되지 않습니다.',
  );
}
