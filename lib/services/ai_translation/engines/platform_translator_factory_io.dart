import 'dart:io';
import '../comic_translator_engine.dart';
import 'on_device_comic_translator.dart';
import 'stub_comic_translator.dart';

ComicTranslatorEngine createPlatformOnDeviceEngine() {
  if (Platform.isAndroid || Platform.isIOS) {
    return OnDeviceComicTranslator();
  }
  return StubComicTranslator(
    unsupportedReason:
        'Windows 데스크톱 환경에서는 온디바이스 ML Kit OCR이 비활성화되어 있습니다. (Phase 2 클라우드 비전 엔진에서 지원 예정)',
  );
}
