import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../../../models/ai_translation/translated_bubble.dart';
import '../../../models/viewer_settings.dart';
import '../bubble_clusterer.dart';
import '../comic_translator_engine.dart';
import 'on_device_comic_translator.dart';

typedef PageBubbleExtractor = Future<List<ExtractedBubbleCandidate>> Function(
  ComicPageTranslationRequest request,
);

class _BatchTranslationItem {
  final ExtractedBubbleCandidate candidate;
  final String queryText;

  const _BatchTranslationItem({
    required this.candidate,
    required this.queryText,
  });
}

/// [온라인 무료 하이브리드 엔진 - 토큰/API Key 불필요]
///
/// 1단계: [OnDeviceComicTranslator]의 ML Kit OCR + [BubbleClusterer] + [BubbleColorSampler] 재사용
/// 2단계: 페이지 내 모든 말풍선 문장을 고유 구분자(`\n|||\n`)로 결합해
///        구글 번역 무료 엔드포인트(`translate.googleapis.com/translate_a/single?client=gtx`)에
///        **페이지당 1회 HTTP GET** 요청으로 일괄 번역 후 각 좌표에 매핑
/// 3단계: 오프라인 상태·타임아웃·일시 제한(HTTP 429 등) 발생 시 앱 중단 없이
///        자동으로 [로컬 오프라인(ML Kit)] 엔진으로 폴백
class FreeGoogleComicTranslator implements ComicTranslatorEngine {
  static const String batchDelimiter = '\n|||\n';
  static const String googleTranslateEndpoint =
      'https://translate.googleapis.com/translate_a/single';

  final OnDeviceComicTranslator? _onDeviceTranslator;
  final ComicTranslatorEngine? _fallbackEngine;
  final PageBubbleExtractor? _bubbleExtractor;
  final Dio _dio;
  final void Function(String message)? onNotice;
  final bool? _isSupportedOverride;

  CancelToken? _activeCancelToken;
  bool _lastRunUsedFallback = false;
  bool _lastRunFallbackEmpty = false;

  FreeGoogleComicTranslator({
    OnDeviceComicTranslator? onDeviceTranslator,
    this._fallbackEngine,
    PageBubbleExtractor? bubbleExtractor,
    Dio? dio,
    this.onNotice,
    this._isSupportedOverride,
  })  : _onDeviceTranslator = onDeviceTranslator ??
            (bubbleExtractor == null ? OnDeviceComicTranslator() : null),
        _bubbleExtractor = bubbleExtractor,
        _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 6),
                receiveTimeout: const Duration(seconds: 8),
              ),
            );

  /// 직전 `translatePage` 호출에서 로컬 오프라인 폴백이 실행되었는지 여부
  bool get lastRunUsedFallback => _lastRunUsedFallback;

  /// 오프라인 폴백이 실행되었지만 로컬 언어팩 미설치 등으로 번역 결과가 비어 캐시를 건너뛰어야 하는지 여부
  bool get shouldCacheLastResult => !_lastRunFallbackEmpty;

  @override
  String get engineId => 'free_google_hybrid_v1';

  @override
  String get displayName => '온라인 무료 (로컬 OCR + 구글 번역)';

  @override
  bool get isSupported =>
      _isSupportedOverride ?? (_onDeviceTranslator?.isSupported ?? true);

  @override
  String? get unsupportedReason => isSupported
      ? null
      : 'Android 및 iPadOS 환경에서만 로컬 OCR 기반 무료 번역이 동작합니다.';

  @override
  Future<void> initialize({required ComicSourceLanguage sourceLanguage}) async {
    // 오프라인 폴백 대비를 위해 백그라운드 언어팩 확인도 함께 워밍업
    await _onDeviceTranslator?.initialize(sourceLanguage: sourceLanguage);
    if (_fallbackEngine != null &&
        !identical(_fallbackEngine, _onDeviceTranslator)) {
      await _fallbackEngine.initialize(sourceLanguage: sourceLanguage);
    }
  }

  @override
  Future<List<TranslatedBubble>> translatePage(
    ComicPageTranslationRequest request,
  ) async {
    _lastRunUsedFallback = false;
    _lastRunFallbackEmpty = false;

    if (!isSupported || request.imageBytes.isEmpty) {
      return const [];
    }

    // 1단계: 기존 OnDeviceComicTranslator의 OCR + 클러스터링 + 배경색 샘플링 로직 재사용
    final extractor =
        _bubbleExtractor ?? _onDeviceTranslator!.extractBubbleCandidates;
    final candidates = await extractor(request);
    if (candidates.isEmpty) {
      return const [];
    }

    final translatable = <_BatchTranslationItem>[];
    for (final c in candidates) {
      if (c.detectedLanguageCode == request.targetLanguage) continue;
      final cleaned = sanitizeBubbleTextForBatch(
        c.cluster.mergedText,
        languageCode: c.detectedLanguageCode,
        sourceLanguage: request.sourceLanguage,
        isVertical: c.cluster.isVertical,
      );
      if (cleaned.isEmpty) continue;
      translatable.add(_BatchTranslationItem(candidate: c, queryText: cleaned));
    }

    if (translatable.isEmpty) {
      return const [];
    }

    final cancelToken = CancelToken();
    _activeCancelToken = cancelToken;

    try {
      // 2단계: 고유 구분자(\n|||\n) 기반 페이지당 1회 무료 구글 번역 HTTP GET 배치 요청
      final translatedParts = await _translateBatchViaFreeGoogle(
        translatable,
        sourceLanguage: request.sourceLanguage,
        targetLanguage: request.targetLanguage,
        cancelToken: cancelToken,
      );

      final bubbles = <TranslatedBubble>[];
      for (int i = 0; i < translatable.length; i++) {
        final translatedText = translatedParts[i].trim();
        if (translatedText.isEmpty) continue;

        final item = translatable[i];
        final candidate = item.candidate;
        bubbles.add(TranslatedBubble(
          normalizedRect: candidate.cluster.normalizedRect,
          originalText: item.queryText,
          translatedText: translatedText,
          backgroundColor: candidate.colors.backgroundColor,
          textColor: candidate.colors.textColor,
          isVerticalSource: candidate.cluster.isVertical,
        ));
      }

      return bubbles;
    } on DioException catch (e) {
      if (CancelToken.isCancel(e) || e.type == DioExceptionType.cancel) {
        return const [];
      }
      debugPrint(
        '[FreeGoogleComicTranslator] 무료 구글 번역 네트워크/제한 오류 (p.${request.pageIndex}): ${e.message} -> 로컬 오프라인 폴백',
      );
      return await _fallbackToOffline(
        request,
        candidates,
        translatable.map((e) => e.candidate).toList(),
      );
    } catch (e) {
      debugPrint(
        '[FreeGoogleComicTranslator] 무료 구글 번역 처리 오류 (p.${request.pageIndex}): $e -> 로컬 오프라인 폴백',
      );
      return await _fallbackToOffline(
        request,
        candidates,
        translatable.map((e) => e.candidate).toList(),
      );
    } finally {
      if (identical(_activeCancelToken, cancelToken)) {
        _activeCancelToken = null;
      }
    }
  }

  Future<List<TranslatedBubble>> _fallbackToOffline(
    ComicPageTranslationRequest request,
    List<ExtractedBubbleCandidate> candidates,
    List<ExtractedBubbleCandidate> translatable,
  ) async {
    _lastRunUsedFallback = true;
    onNotice?.call(
      '네트워크 또는 무료 번역 제한으로 로컬 오프라인(ML Kit) 엔진으로 자동 전환합니다.',
    );

    try {
      List<TranslatedBubble> fallbackBubbles;
      if (_fallbackEngine != null) {
        fallbackBubbles = await _fallbackEngine.translatePage(request);
      } else if (_onDeviceTranslator != null) {
        fallbackBubbles = await _onDeviceTranslator.translateCandidatesOffline(
          request,
          candidates,
          allowWebFallback: false,
        );
      } else {
        fallbackBubbles = const [];
      }

      if (fallbackBubbles.isEmpty && translatable.isNotEmpty) {
        _lastRunFallbackEmpty = true;
      }
      return fallbackBubbles;
    } catch (e) {
      debugPrint('[FreeGoogleComicTranslator] 로컬 오프라인 폴백 실패: $e');
      if (translatable.isNotEmpty) {
        _lastRunFallbackEmpty = true;
      }
      return const [];
    }
  }

  Future<List<String>> _translateBatchViaFreeGoogle(
    List<_BatchTranslationItem> translatable, {
    required ComicSourceLanguage sourceLanguage,
    required String targetLanguage,
    required CancelToken cancelToken,
  }) async {
    final sanitizedInputs = translatable.map((item) => item.queryText).toList();
    final joinedQuery = sanitizedInputs.join(batchDelimiter);

    final sl = _resolveBatchSourceLanguage(
      sourceLanguage,
      translatable.map((e) => e.candidate).toList(),
    );
    final tl = _toGoogleLangCode(targetLanguage);

    final response = await _dio.get<dynamic>(
      googleTranslateEndpoint,
      cancelToken: cancelToken,
      queryParameters: <String, dynamic>{
        'client': 'gtx',
        'sl': sl,
        'tl': tl,
        'dt': 't',
        'q': joinedQuery,
      },
      options: Options(
        responseType: ResponseType.json,
      ),
    );

    if (response.statusCode != null && response.statusCode != 200) {
      throw DioException.badResponse(
        statusCode: response.statusCode!,
        requestOptions: response.requestOptions,
        response: response,
      );
    }

    final fullTranslated = parseGoogleSingleResponse(response.data);
    return splitBatchTranslations(
      fullTranslated,
      expectedCount: translatable.length,
    );
  }

  /// `translate_a/single` JSON 응답 배열에서 번역된 전체 텍스트를 추출합니다.
  @visibleForTesting
  static String parseGoogleSingleResponse(dynamic rawData) {
    final dynamic decoded;
    if (rawData is String) {
      if (rawData.trim().isEmpty) {
        throw const FormatException('Empty Google Translate response');
      }
      decoded = jsonDecode(rawData);
    } else {
      decoded = rawData;
    }

    if (decoded is! List || decoded.isEmpty || decoded[0] is! List) {
      throw const FormatException('Invalid Google Translate response format');
    }

    final segments = decoded[0] as List;
    final sb = StringBuffer();
    for (final segment in segments) {
      if (segment is List && segment.isNotEmpty && segment[0] != null) {
        sb.write(segment[0].toString());
      }
    }
    return sb.toString();
  }

  /// 일괄 번역된 문자열을 고유 구분자(`|||`) 기준으로 분리해 각 말풍선에 매핑합니다.
  @visibleForTesting
  static List<String> splitBatchTranslations(
    String translated, {
    required int expectedCount,
  }) {
    if (expectedCount <= 0) return const [];
    if (expectedCount == 1) return [translated.trim()];

    final primaryParts = translated.split(RegExp(r'\s*\|\|\|\s*'));
    if (primaryParts.length == expectedCount) {
      return primaryParts.map((s) => s.trim()).toList();
    }

    // 간혹 번역기가 파이프 문자 사이에 공백을 넣은 경우 보조 매칭
    final spacedPipeParts = translated.split(RegExp(r'\s*\|\s*\|\s*\|\s*'));
    if (spacedPipeParts.length == expectedCount) {
      return spacedPipeParts.map((s) => s.trim()).toList();
    }

    throw FormatException(
      'Batch translation delimiter mismatch: expected $expectedCount, got ${primaryParts.length}',
    );
  }

  /// 배치(`\n|||\n`) 전송 전 OCR 오인식 특수기호·단일 문자 노이즈를 정제하고
  /// 언어 스크립트별 줄바꿈 규칙을 적용합니다. 노이즈만 남은 경우 빈 문자열을 반환합니다.
  @visibleForTesting
  static String sanitizeBubbleTextForBatch(
    String text, {
    String? languageCode,
    ComicSourceLanguage sourceLanguage = ComicSourceLanguage.auto,
    bool isVertical = false,
  }) {
    final withoutDelimiter = text.replaceAll('|||', ' ');
    final bool? isCjkScript;
    if (sourceLanguage == ComicSourceLanguage.japanese ||
        sourceLanguage == ComicSourceLanguage.chinese ||
        languageCode == 'ja' ||
        languageCode == 'zh' ||
        languageCode == 'zh-CN') {
      isCjkScript = true;
    } else if (sourceLanguage == ComicSourceLanguage.english ||
        languageCode == 'en' ||
        languageCode == 'es') {
      isCjkScript = false;
    } else {
      isCjkScript = null;
    }

    final cleaned = BubbleClusterer.cleanAndNormalizeText(
      withoutDelimiter,
      isCjkScript: isCjkScript,
      isVertical: isVertical,
    );

    final preferNoSpace = isCjkScript ??
        RegExp(r'[\u3040-\u309F\u30A0-\u30FF\u4E00-\u9FFF\u3400-\u4DBF]')
            .hasMatch(cleaned);

    if (BubbleClusterer.isNoiseText(cleaned, preferNoSpace: preferNoSpace)) {
      return '';
    }
    return cleaned;
  }

  static String _resolveBatchSourceLanguage(
    ComicSourceLanguage configured,
    List<ExtractedBubbleCandidate> translatable,
  ) {
    if (configured != ComicSourceLanguage.auto) {
      return _toGoogleLangCode(configured.bcpCode);
    }
    final distinct = translatable.map((c) => c.detectedLanguageCode).toSet();
    if (distinct.length == 1) {
      return _toGoogleLangCode(distinct.first);
    }
    return 'auto';
  }

  static String _toGoogleLangCode(String bcpCode) {
    if (bcpCode == 'zh') return 'zh-CN';
    return bcpCode;
  }

  @override
  Future<void> dispose() async {
    try {
      _activeCancelToken?.cancel('Engine disposed');
    } catch (_) {}
    _activeCancelToken = null;
    await _onDeviceTranslator?.dispose();
    if (_fallbackEngine != null &&
        !identical(_fallbackEngine, _onDeviceTranslator)) {
      await _fallbackEngine.dispose();
    }
  }
}
