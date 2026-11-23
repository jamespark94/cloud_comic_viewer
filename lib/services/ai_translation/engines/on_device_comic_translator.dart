import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:translator/translator.dart' as web_trans;
import '../../../models/ai_translation/translated_bubble.dart';
import '../../../models/viewer_settings.dart';
import '../bubble_clusterer.dart';
import '../bubble_color_sampler.dart';
import '../comic_translator_engine.dart';

/// 1단계 온디바이스 OCR + 말풍선 클러스터링 + 배경색 샘플링 추출 결과
class ExtractedBubbleCandidate {
  final ClusteredBubble cluster;
  final BubbleColors colors;
  final String detectedLanguageCode;

  const ExtractedBubbleCandidate({
    required this.cluster,
    required this.colors,
    required this.detectedLanguageCode,
  });
}

/// [Phase 1 온디바이스 오프라인 무료 엔진 - Android & iPadOS 전용]
/// 1. ML Kit TextRecognizer(일본어/영어/중국어)로 텍스트 라인 및 BoundingBox 추출
/// 2. BubbleClusterer로 말풍선 단위 병합 (일본 만화 세로쓰기 우->좌 정렬)
/// 3. BubbleColorSampler로 말풍선 테두리 픽셀 샘플링 기반 배경 대표색 추정
/// 4. ML Kit OnDeviceTranslator (언어팩 다운로드 중에는 무료 translator 패키지 폴백)
class OnDeviceComicTranslator implements ComicTranslatorEngine {
  final Map<TextRecognitionScript, TextRecognizer> _recognizers = {};
  final Map<String, OnDeviceTranslator> _mlkitTranslators = {};
  final OnDeviceTranslatorModelManager _modelManager =
      OnDeviceTranslatorModelManager();
  final Set<String> _readyModels = {};
  final Set<String> _downloadingModels = {};
  final web_trans.GoogleTranslator _fallbackTranslator =
      web_trans.GoogleTranslator();

  ComicSourceLanguage _initializedLang = ComicSourceLanguage.auto;

  @override
  String get engineId => 'on_device_mlkit_v1';

  @override
  String get displayName => '로컬 오프라인 (ML Kit)';

  @override
  bool get isSupported => Platform.isAndroid || Platform.isIOS;

  @override
  String? get unsupportedReason =>
      isSupported ? null : 'Android 및 iPadOS 환경에서만 온디바이스 OCR이 동작합니다.';

  @override
  Future<void> initialize({required ComicSourceLanguage sourceLanguage}) async {
    _initializedLang = sourceLanguage;
    // 한국어 타겟 언어팩 및 선택된 원본 언어팩을 백그라운드에서 사전 확인/다운로드
    unawaited(_ensureModelInBackground('ko'));
    if (sourceLanguage != ComicSourceLanguage.auto) {
      unawaited(_ensureModelInBackground(sourceLanguage.bcpCode));
    } else {
      unawaited(_ensureModelInBackground('ja'));
      unawaited(_ensureModelInBackground('en'));
    }
  }

  /// 1단계: ML Kit OCR + 말풍선 병합(Clustering) + 배경색 샘플링 수행
  /// ([FreeGoogleComicTranslator]에서도 동일 로직을 재사용합니다.)
  Future<List<ExtractedBubbleCandidate>> extractBubbleCandidates(
    ComicPageTranslationRequest request,
  ) async {
    if (!isSupported || request.imageBytes.isEmpty) {
      return const [];
    }

    final script = _resolveScript(
      request.sourceLanguage,
      isRtlManga: request.isRightToLeftManga,
    );

    File? tempImgFile;
    try {
      tempImgFile = await _writeTempImage(request.imageBytes, request.pageIndex);
      final inputImage = InputImage.fromFilePath(tempImgFile.path);

      var recognized = await _getRecognizer(script).processImage(inputImage);

      // 자동 모드 & 좌->우 만화에서 라틴 OCR 결과가 없으면 일본어 OCR 재시도
      if (recognized.blocks.isEmpty &&
          request.sourceLanguage == ComicSourceLanguage.auto &&
          script == TextRecognitionScript.latin) {
        recognized = await _getRecognizer(TextRecognitionScript.japanese)
            .processImage(inputImage);
      }

      if (recognized.blocks.isEmpty) {
        return const [];
      }

      // TextLine 단위로 추출해 말풍선 클러스터링 수행
      final ocrLines = <OcrTextLine>[];
      for (final block in recognized.blocks) {
        if (block.lines.isEmpty) {
          ocrLines.add(OcrTextLine(
            text: block.text,
            boundingBox: block.boundingBox,
          ));
        } else {
          for (final line in block.lines) {
            ocrLines.add(OcrTextLine(
              text: line.text,
              boundingBox: line.boundingBox,
              angle: line.angle,
            ));
          }
        }
      }

      final clusters = BubbleClusterer.clusterLines(
        lines: ocrLines,
        imageWidth: request.imageWidth,
        imageHeight: request.imageHeight,
        preferVerticalRtl: request.isRightToLeftManga ||
            request.sourceLanguage == ComicSourceLanguage.japanese,
        sourceLanguage: request.sourceLanguage,
      );

      if (clusters.isEmpty) return const [];

      // 말풍선 테두리 픽셀 샘플링으로 배경 대표색 추정
      final sampledColors = await BubbleColorSampler.sampleColors(
        imageBytes: request.imageBytes,
        normalizedRects: clusters.map((c) => c.normalizedRect).toList(),
      );

      final candidates = <ExtractedBubbleCandidate>[];
      for (int i = 0; i < clusters.length; i++) {
        final cluster = clusters[i];
        final colors = sampledColors[i];
        final srcLangCode = _detectTextLanguage(
          cluster.mergedText,
          configured: request.sourceLanguage,
          isRtlManga: request.isRightToLeftManga,
        );
        candidates.add(ExtractedBubbleCandidate(
          cluster: cluster,
          colors: colors,
          detectedLanguageCode: srcLangCode,
        ));
      }

      return candidates;
    } catch (e) {
      debugPrint(
        '[OnDeviceComicTranslator] OCR 추출 실패 (p.${request.pageIndex}): $e',
      );
      return const [];
    } finally {
      if (tempImgFile != null) {
        unawaited(tempImgFile.delete().catchError((_) => tempImgFile!));
      }
    }
  }

  /// 이미 추출된 말풍선 후보 리스트를 로컬 오프라인(ML Kit) 엔진으로 번역합니다.
  Future<List<TranslatedBubble>> translateCandidatesOffline(
    ComicPageTranslationRequest request,
    List<ExtractedBubbleCandidate> candidates, {
    bool allowWebFallback = true,
  }) async {
    if (candidates.isEmpty) return const [];

    final bubbles = <TranslatedBubble>[];
    for (final candidate in candidates) {
      // 이미 타겟 언어(한국어)인 경우 번역 불필요
      if (candidate.detectedLanguageCode == request.targetLanguage) {
        continue;
      }

      final translated = await _translateText(
        candidate.cluster.mergedText,
        fromCode: candidate.detectedLanguageCode,
        toCode: request.targetLanguage,
        allowWebFallback: allowWebFallback,
      );

      if (translated == null || translated.trim().isEmpty) continue;

      bubbles.add(TranslatedBubble(
        normalizedRect: candidate.cluster.normalizedRect,
        originalText: candidate.cluster.mergedText,
        translatedText: translated.trim(),
        backgroundColor: candidate.colors.backgroundColor,
        textColor: candidate.colors.textColor,
        isVerticalSource: candidate.cluster.isVertical,
      ));
    }

    return bubbles;
  }

  @override
  Future<List<TranslatedBubble>> translatePage(
    ComicPageTranslationRequest request,
  ) async {
    if (!isSupported || request.imageBytes.isEmpty) {
      return const [];
    }

    try {
      final candidates = await extractBubbleCandidates(request);
      if (candidates.isEmpty) return const [];
      return await translateCandidatesOffline(request, candidates);
    } catch (e) {
      debugPrint('[OnDeviceComicTranslator] 페이지 번역 실패 (p.${request.pageIndex}): $e');
      return const [];
    }
  }

  TextRecognitionScript _resolveScript(
    ComicSourceLanguage sourceLang, {
    required bool isRtlManga,
  }) {
    switch (sourceLang) {
      case ComicSourceLanguage.japanese:
        return TextRecognitionScript.japanese;
      case ComicSourceLanguage.chinese:
        return TextRecognitionScript.chinese;
      case ComicSourceLanguage.english:
        return TextRecognitionScript.latin;
      case ComicSourceLanguage.auto:
        return isRtlManga
            ? TextRecognitionScript.japanese
            : TextRecognitionScript.latin;
    }
  }

  TextRecognizer _getRecognizer(TextRecognitionScript script) {
    return _recognizers.putIfAbsent(
      script,
      () => TextRecognizer(script: script),
    );
  }

  Future<File> _writeTempImage(Uint8List bytes, int pageIndex) async {
    final dir = await getTemporaryDirectory();
    final ext = _detectImageExt(bytes);
    final fileName =
        'ocr_tmp_${DateTime.now().microsecondsSinceEpoch}_$pageIndex$ext';
    final file = File(p.join(dir.path, fileName));
    await file.writeAsBytes(bytes, flush: false);
    return file;
  }

  String _detectImageExt(Uint8List bytes) {
    if (bytes.length >= 4 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return '.png';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45) {
      return '.webp';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46) {
      return '.gif';
    }
    return '.jpg';
  }

  String _detectTextLanguage(
    String text, {
    required ComicSourceLanguage configured,
    required bool isRtlManga,
  }) {
    if (configured != ComicSourceLanguage.auto) {
      return configured.bcpCode;
    }
    if (RegExp(r'[\uAC00-\uD7AF\u1100-\u11FF]').hasMatch(text)) {
      return 'ko';
    }
    if (RegExp(r'[\u3040-\u309F\u30A0-\u30FF]').hasMatch(text)) {
      return 'ja';
    }
    if (RegExp(r'[\u4E00-\u9FFF]').hasMatch(text)) {
      return isRtlManga ? 'ja' : 'zh';
    }
    if (RegExp(r'[¡¿ñÑ]').hasMatch(text)) {
      return 'es';
    }
    if (RegExp(r'[\u00C0-\u024F]').hasMatch(text)) {
      return 'auto';
    }
    return 'en';
  }

  Future<String?> _translateText(
    String text, {
    required String fromCode,
    required String toCode,
    bool allowWebFallback = true,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;

    // 1순위: ML Kit 온디바이스 번역기 (오프라인 언어팩이 준비된 경우 즉시 로컬 추론)
    final srcReady = await _isModelReady(fromCode);
    final tgtReady = await _isModelReady(toCode);

    if (srcReady && tgtReady) {
      final srcLang = BCP47Code.fromRawValue(fromCode);
      final tgtLang = BCP47Code.fromRawValue(toCode);
      if (srcLang != null && tgtLang != null) {
        try {
          final key = '${fromCode}_$toCode';
          final translator = _mlkitTranslators.putIfAbsent(
            key,
            () => OnDeviceTranslator(
              sourceLanguage: srcLang,
              targetLanguage: tgtLang,
            ),
          );
          final result = await translator.translateText(trimmed);
          if (result.trim().isNotEmpty) {
            return result.trim();
          }
        } catch (e) {
          debugPrint('[OnDeviceComicTranslator] ML Kit 번역 실패, 폴백 시도: $e');
        }
      }
    } else {
      // 언어팩 미설치 시 백그라운드 다운로드 트리거 후 필요 시 무료 translator 폴백 실행
      unawaited(_ensureModelInBackground(fromCode));
      unawaited(_ensureModelInBackground(toCode));
    }

    if (!allowWebFallback) {
      return null;
    }

    // 2순위: 순수 Dart 무료 translator 폴백 (언어팩 다운로드 대기 시간 0ms)
    try {
      final fbFrom = fromCode == 'zh' ? 'zh-cn' : fromCode;
      final res = await _fallbackTranslator
          .translate(trimmed, from: fbFrom, to: toCode)
          .timeout(const Duration(seconds: 6));
      if (res.text.trim().isNotEmpty) {
        return res.text.trim();
      }
    } catch (e) {
      debugPrint('[OnDeviceComicTranslator] 폴백 번역 실패: $e');
    }

    return null;
  }

  Future<bool> _isModelReady(String bcpCode) async {
    if (_readyModels.contains(bcpCode)) return true;
    try {
      final downloaded = await _modelManager.isModelDownloaded(bcpCode);
      if (downloaded) {
        _readyModels.add(bcpCode);
      }
      return downloaded;
    } catch (_) {
      return false;
    }
  }

  Future<void> _ensureModelInBackground(String bcpCode) async {
    if (_readyModels.contains(bcpCode) || _downloadingModels.contains(bcpCode)) {
      return;
    }
    _downloadingModels.add(bcpCode);
    try {
      final already = await _modelManager.isModelDownloaded(bcpCode);
      if (already) {
        _readyModels.add(bcpCode);
        return;
      }
      final ok = await _modelManager.downloadModel(
        bcpCode,
        isWifiRequired: false,
      );
      if (ok) {
        _readyModels.add(bcpCode);
      }
    } catch (e) {
      debugPrint('[OnDeviceComicTranslator] 언어팩($_initializedLang/$bcpCode) 다운로드 경고: $e');
    } finally {
      _downloadingModels.remove(bcpCode);
    }
  }

  @override
  Future<void> dispose() async {
    final recs = _recognizers.values.toList();
    _recognizers.clear();
    for (final r in recs) {
      try {
        await r.close();
      } catch (_) {}
    }

    final trans = _mlkitTranslators.values.toList();
    _mlkitTranslators.clear();
    for (final t in trans) {
      try {
        await t.close();
      } catch (_) {}
    }
    _readyModels.clear();
    _downloadingModels.clear();
  }
}
