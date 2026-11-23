import 'dart:io';
import '../comic_translator_engine.dart';
import 'free_google_comic_translator.dart';
import 'on_device_comic_translator.dart';
import 'stub_comic_translator.dart';

ComicTranslatorEngine createPlatformOnDeviceEngine() {
  if (Platform.isAndroid || Platform.isIOS) {
    return OnDeviceComicTranslator();
  }
  return StubComicTranslator(
    unsupportedReason:
        'Windows 데스크톱 환경에서는 온디바이스 ML Kit OCR이 비활성화되어 있습니다. (클라우드 AI 엔진에서 지원)',
  );
}

ComicTranslatorEngine createPlatformFreeGoogleEngine({
  ComicTranslatorEngine? onDeviceEngine,
  void Function(String message)? onNotice,
}) {
  if (Platform.isAndroid || Platform.isIOS) {
    final baseOnDevice = onDeviceEngine is OnDeviceComicTranslator
        ? onDeviceEngine
        : OnDeviceComicTranslator();
    return FreeGoogleComicTranslator(
      onDeviceTranslator: baseOnDevice,
      onNotice: onNotice,
    );
  }
  return StubComicTranslator(
    unsupportedReason:
        'Windows 데스크톱 환경에서는 로컬 OCR 기반 무료 번역이 비활성화되어 있습니다. (클라우드 AI 엔진에서 지원)',
  );
}
