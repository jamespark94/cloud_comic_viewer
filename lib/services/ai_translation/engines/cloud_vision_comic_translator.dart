import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import '../../../models/ai_translation/translated_bubble.dart';
import '../../../models/viewer_settings.dart';
import '../comic_translation_key_storage.dart';
import '../comic_translator_engine.dart';

/// 클라우드 비전 AI 오류 분류
enum CloudVisionErrorType {
  missingApiKey,
  invalidApiKey,
  quotaExceeded,
  networkError,
  invalidResponse,
  cancelled,
}

class CloudVisionException implements Exception {
  final CloudVisionErrorType type;
  final String message;
  final int? statusCode;

  const CloudVisionException(
    this.type,
    this.message, {
    this.statusCode,
  });

  @override
  String toString() => 'CloudVisionException($type): $message';
}

/// [Phase 2] Gemini 멀티모달 비전(Vision) API 기반 고품질 만화 번역 엔진.
///
/// 1. 백그라운드 Isolate에서 이미지를 장변 최대 1440px JPEG로 경량 리사이징/압축
/// 2. Gemini Structured Output(JSON Schema)을 사용해 단일 API 호출로
///    [정규화 좌표(ymin, xmin, ymax, xmax) + 배경색 Hex + 원문 + 만화 문맥 한국어 의역] 수신
/// 3. Android / iPadOS / Windows 모든 플랫폼에서 동일하게 동작
class CloudVisionComicTranslator implements ComicTranslatorEngine {
  static const int defaultMaxDimension = 1440;
  static const int defaultJpegQuality = 82;

  static const List<String> _fallbackModels = <String>[
    'gemini-2.5-flash',
    'gemini-3-flash-preview',
    'gemini-3.1-flash-lite',
    'gemini-2.0-flash',
  ];

  static String? _globalWorkingModel;

  final String? apiKey;
  final Future<String?> Function()? apiKeyProvider;
  final String modelName;
  final int maxDimension;
  final int jpegQuality;
  final bool enableModelFallback;
  final Dio _dio;

  String? _resolvedApiKey;
  String? _resolvedModelName;
  CancelToken? _activeCancelToken;

  CloudVisionComicTranslator({
    this.apiKey,
    this.apiKeyProvider,
    this.modelName = 'gemini-2.5-flash',
    this.maxDimension = defaultMaxDimension,
    this.jpegQuality = defaultJpegQuality,
    this.enableModelFallback = true,
    Dio? dio,
  }) : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 20),
                sendTimeout: const Duration(seconds: 40),
                receiveTimeout: const Duration(seconds: 60),
              ),
            );

  String get _activeModelName {
    if (_resolvedModelName != null) return _resolvedModelName!;
    if (modelName == 'gemini-2.5-flash' && _globalWorkingModel != null) {
      return _globalWorkingModel!;
    }
    return modelName;
  }

  @override
  String get engineId => 'cloud_vision_$_activeModelName';

  @override
  String get displayName => '클라우드 고품질 AI ($_activeModelName)';

  @override
  bool get isSupported {
    final direct = apiKey?.trim();
    if (direct != null && direct.isNotEmpty) return true;
    return ComicTranslationKeyStorage.instance.hasCachedApiKey;
  }

  @override
  String? get unsupportedReason => isSupported
      ? null
      : '클라우드 고품질 모드를 사용하려면 설정에서 Gemini API Key를 먼저 입력·저장해 주세요.';

  Future<String?> _getApiKey() async {
    final direct = apiKey?.trim();
    if (direct != null && direct.isNotEmpty) return direct;
    if (apiKeyProvider != null) {
      final provided = (await apiKeyProvider!())?.trim();
      if (provided != null && provided.isNotEmpty) return provided;
    }
    final stored =
        (await ComicTranslationKeyStorage.instance.loadApiKey())?.trim();
    if (stored != null && stored.isNotEmpty) return stored;
    return null;
  }

  @override
  Future<void> initialize({required ComicSourceLanguage sourceLanguage}) async {
    final key = await _getApiKey();
    if (key == null || key.isEmpty) {
      throw const CloudVisionException(
        CloudVisionErrorType.missingApiKey,
        'Gemini API Key가 설정되지 않았습니다. 뷰어 설정에서 키를 입력해 주세요.',
      );
    }
    _resolvedApiKey = key;
  }

  @override
  Future<List<TranslatedBubble>> translatePage(
    ComicPageTranslationRequest request,
  ) async {
    if (request.imageBytes.isEmpty) return const [];

    final key = _resolvedApiKey ?? await _getApiKey();
    if (key == null || key.isEmpty) {
      throw const CloudVisionException(
        CloudVisionErrorType.missingApiKey,
        'Gemini API Key가 설정되지 않았습니다.',
      );
    }

    // 1. 백그라운드 Isolate에서 적정 해상도(장변 1280~1600px, 기본 1440px) JPEG 압축
    final maxDim = maxDimension;
    final quality = jpegQuality;
    final rawBytes = request.imageBytes;
    final prepared = await Isolate.run(
      () => prepareImageForVisionApi(
        rawBytes,
        maxDimension: maxDim,
        jpegQuality: quality,
      ),
    );

    final base64Img = base64Encode(prepared.bytes);
    final cancelToken = CancelToken();
    _activeCancelToken = cancelToken;

    try {
      final responseData = await _requestGeminiWithModelFallback(
        apiKey: key,
        base64Image: base64Img,
        mimeType: prepared.mimeType,
        request: request,
        cancelToken: cancelToken,
      );

      return parseGeminiResponse(responseData);
    } finally {
      if (identical(_activeCancelToken, cancelToken)) {
        _activeCancelToken = null;
      }
    }
  }

  /// 이미지를 장변 [maxDimension]px 이하의 경량 JPEG 바이트로 변환합니다.
  @visibleForTesting
  static ({Uint8List bytes, String mimeType}) prepareImageForVisionApi(
    Uint8List sourceBytes, {
    int maxDimension = defaultMaxDimension,
    int jpegQuality = defaultJpegQuality,
  }) {
    try {
      final decoded = img.decodeImage(sourceBytes);
      if (decoded == null) {
        return (bytes: sourceBytes, mimeType: _detectMimeType(sourceBytes));
      }

      final longEdge = max(decoded.width, decoded.height);
      final processed = longEdge > maxDimension
          ? img.copyResize(
              decoded,
              width: decoded.width >= decoded.height ? maxDimension : null,
              height: decoded.height > decoded.width ? maxDimension : null,
              interpolation: img.Interpolation.linear,
            )
          : decoded;

      final encoded = img.encodeJpg(processed, quality: jpegQuality);
      return (bytes: Uint8List.fromList(encoded), mimeType: 'image/jpeg');
    } catch (_) {
      return (bytes: sourceBytes, mimeType: _detectMimeType(sourceBytes));
    }
  }

  static String _detectMimeType(Uint8List bytes) {
    if (bytes.length >= 4 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45) {
      return 'image/webp';
    }
    return 'image/jpeg';
  }

  Future<Map<String, dynamic>> _requestGeminiWithModelFallback({
    required String apiKey,
    required String base64Image,
    required String mimeType,
    required ComicPageTranslationRequest request,
    required CancelToken cancelToken,
  }) async {
    final payload = buildGeminiRequestBody(
      base64Image: base64Image,
      mimeType: mimeType,
      sourceLanguage: request.sourceLanguage,
      isRightToLeftManga: request.isRightToLeftManga,
    );

    final candidates = <String>[
      _activeModelName,
      if (enableModelFallback) ..._fallbackModels,
    ];
    final tried = <String>{};
    CloudVisionException? lastNotFoundError;

    for (final candidate in candidates) {
      if (!tried.add(candidate)) continue;
      try {
        final res = await _postGenerateContent(
          model: candidate,
          apiKey: apiKey,
          payload: payload,
          cancelToken: cancelToken,
        );
        _resolvedModelName = candidate;
        _globalWorkingModel = candidate;
        return res;
      } on CloudVisionException catch (e) {
        if (e.statusCode == 404 && enableModelFallback) {
          lastNotFoundError = e;
          debugPrint(
            '[CloudVisionComicTranslator] 모델 $candidate 404 -> 대체 모델 시도',
          );
          continue;
        }
        rethrow;
      }
    }

    if (enableModelFallback) {
      final discovered = await _discoverAvailableFlashModel(
        apiKey: apiKey,
        cancelToken: cancelToken,
      );
      if (discovered != null && !tried.contains(discovered)) {
        final res = await _postGenerateContent(
          model: discovered,
          apiKey: apiKey,
          payload: payload,
          cancelToken: cancelToken,
        );
        _resolvedModelName = discovered;
        _globalWorkingModel = discovered;
        return res;
      }
    }

    throw lastNotFoundError ??
        const CloudVisionException(
          CloudVisionErrorType.invalidResponse,
          '사용 가능한 Gemini Vision 모델을 찾을 수 없습니다 (HTTP 404).',
          statusCode: 404,
        );
  }

  Future<String?> _discoverAvailableFlashModel({
    required String apiKey,
    required CancelToken cancelToken,
  }) async {
    try {
      final res = await _dio.get<dynamic>(
        'https://generativelanguage.googleapis.com/v1beta/models',
        cancelToken: cancelToken,
        options: Options(
          headers: <String, dynamic>{'x-goog-api-key': apiKey},
          responseType: ResponseType.json,
        ),
      );
      final data = res.data;
      if (data is! Map<String, dynamic>) return null;
      final models = data['models'];
      if (models is! List) return null;

      final validFlashNames = <String>[];
      for (final m in models) {
        if (m is! Map<String, dynamic>) continue;
        final name = (m['name'] as String?) ?? '';
        final methods = m['supportedGenerationMethods'];
        final supportsGenerate =
            methods is List && methods.contains('generateContent');
        if (!supportsGenerate) continue;
        final shortName =
            name.startsWith('models/') ? name.substring('models/'.length) : name;
        if (shortName.contains('flash') &&
            !shortName.contains('tts') &&
            !shortName.contains('image')) {
          validFlashNames.add(shortName);
        }
      }
      if (validFlashNames.isEmpty) return null;
      validFlashNames.sort((a, b) => b.compareTo(a));
      return validFlashNames.first;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> _postGenerateContent({
    required String model,
    required String apiKey,
    required Map<String, dynamic> payload,
    required CancelToken cancelToken,
  }) async {
    final url =
        'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent';
    try {
      final response = await _dio.post<dynamic>(
        url,
        data: payload,
        cancelToken: cancelToken,
        options: Options(
          headers: <String, dynamic>{
            'Content-Type': 'application/json',
            'x-goog-api-key': apiKey,
          },
          responseType: ResponseType.json,
        ),
      );

      final data = response.data;
      if (data is Map<String, dynamic>) return data;
      if (data is String && data.isNotEmpty) {
        final decoded = jsonDecode(data);
        if (decoded is Map<String, dynamic>) return decoded;
      }
      throw const CloudVisionException(
        CloudVisionErrorType.invalidResponse,
        'Gemini Vision 응답 형식이 올바르지 않습니다.',
      );
    } on DioException catch (e) {
      if (CancelToken.isCancel(e) || e.type == DioExceptionType.cancel) {
        throw const CloudVisionException(
          CloudVisionErrorType.cancelled,
          '번역 요청이 취소되었습니다.',
        );
      }
      throw _classifyDioException(e);
    }
  }

  @visibleForTesting
  static Map<String, dynamic> buildGeminiRequestBody({
    required String base64Image,
    required String mimeType,
    required ComicSourceLanguage sourceLanguage,
    required bool isRightToLeftManga,
  }) {
    final langHint = sourceLanguage == ComicSourceLanguage.auto
        ? '자동 감지'
        : '${sourceLanguage.label} (${sourceLanguage.bcpCode})';
    final directionHint = isRightToLeftManga
        ? '일본 만화 우->좌(오른쪽에서 왼쪽, 위에서 아래) 읽기 순서'
        : '일반 좌->우(왼쪽에서 오른쪽, 위에서 아래) 읽기 순서';

    final prompt = '''
당신은 최고의 만화/웹툰 식자 및 문맥 의역 전문가입니다.
첨부된 만화 페이지 이미지에서 대사 말풍선, 나레이션 박스, 의미 있는 자막 텍스트 영역을 모두 찾아 아래 JSON 스키마에 맞춰 반환하세요.

[규칙]
1. 원본 언어 힌트: $langHint / 읽기 순서: $directionHint
2. 각 말풍선(또는 독립 대사 블록)마다 하나의 항목으로 묶으세요. 한 말풍선 안의 여러 줄은 합쳐서 하나의 항목으로 만듭니다.
3. 좌표(ymin, xmin, ymax, xmax)는 이미지 전체 크기 기준 0.0 ~ 1.0 사이의 정규화 소수(예: 0.12, 0.45)로 반환하세요. 원본 글자가 가려지도록 텍스트 영역을 넉넉히 감싸되, 말풍선 테두리 선을 크게 넘지 않게 지정하세요.
4. bgColorHex에는 말풍선 내부 바탕색을 Hex 코드(예: "#FFFFFF", "#141414", "#F5ECD8")로 추정해 넣으세요.
5. originalText에는 이미지에 적힌 원문 대사를 그대로 전사하세요.
6. koreanTranslation에는 직역투를 피하고 캐릭터의 감정·말투(반말/존댓말/감탄사 등)·앞뒤 컷 문맥을 살린 자연스러운 한국어 의역을 작성하세요. 이미 한국어 페이지라면 대사가 없는 것으로 간주하거나 생략하세요.
7. 대사가 전혀 없는 그림/배경 페이지는 bubbles를 빈 배열 []로 반환하세요.
''';

    return <String, dynamic>{
      'contents': [
        {
          'parts': [
            {
              'inlineData': {
                'mimeType': mimeType,
                'data': base64Image,
              },
            },
            {
              'text': prompt,
            },
          ],
        },
      ],
      'generationConfig': {
        'temperature': 0.2,
        'responseMimeType': 'application/json',
        'responseSchema': {
          'type': 'OBJECT',
          'properties': {
            'bubbles': {
              'type': 'ARRAY',
              'items': {
                'type': 'OBJECT',
                'properties': {
                  'ymin': {'type': 'NUMBER'},
                  'xmin': {'type': 'NUMBER'},
                  'ymax': {'type': 'NUMBER'},
                  'xmax': {'type': 'NUMBER'},
                  'bgColorHex': {'type': 'STRING'},
                  'originalText': {'type': 'STRING'},
                  'koreanTranslation': {'type': 'STRING'},
                  'isVertical': {'type': 'BOOLEAN'},
                },
                'required': [
                  'ymin',
                  'xmin',
                  'ymax',
                  'xmax',
                  'bgColorHex',
                  'originalText',
                  'koreanTranslation',
                ],
              },
            },
          },
          'required': ['bubbles'],
        },
      },
    };
  }

  @visibleForTesting
  static List<TranslatedBubble> parseGeminiResponse(
    Map<String, dynamic> responseData,
  ) {
    final candidates = responseData['candidates'];
    if (candidates is! List || candidates.isEmpty) return const [];

    final firstCandidate = candidates.first;
    if (firstCandidate is! Map<String, dynamic>) return const [];
    final content = firstCandidate['content'];
    if (content is! Map<String, dynamic>) return const [];
    final parts = content['parts'];
    if (parts is! List || parts.isEmpty) return const [];

    String? rawText;
    for (final part in parts) {
      if (part is Map<String, dynamic> && part['text'] is String) {
        rawText = part['text'] as String;
        break;
      }
    }
    if (rawText == null || rawText.trim().isEmpty) return const [];

    final cleaned = _stripMarkdownJsonFence(rawText.trim());
    final dynamic decoded;
    try {
      decoded = jsonDecode(cleaned);
    } catch (e) {
      throw CloudVisionException(
        CloudVisionErrorType.invalidResponse,
        'Gemini Vision JSON 파싱 실패: $e',
      );
    }

    if (decoded is! Map<String, dynamic>) return const [];
    final rawBubbles = decoded['bubbles'];
    if (rawBubbles is! List) return const [];

    final results = <TranslatedBubble>[];
    for (final item in rawBubbles) {
      if (item is! Map<String, dynamic>) continue;

      var ymin = (item['ymin'] as num?)?.toDouble();
      var xmin = (item['xmin'] as num?)?.toDouble();
      var ymax = (item['ymax'] as num?)?.toDouble();
      var xmax = (item['xmax'] as num?)?.toDouble();
      if (ymin == null || xmin == null || ymax == null || xmax == null) {
        continue;
      }

      // Gemini가 0~1000 스케일 정수를 반환한 경우에도 안전하게 0.0~1.0으로 정규화
      final maxVal = [ymin, xmin, ymax, xmax].reduce(max);
      if (maxVal > 1.01) {
        ymin /= 1000.0;
        xmin /= 1000.0;
        ymax /= 1000.0;
        xmax /= 1000.0;
      }

      final clampedL = xmin.clamp(0.0, 1.0);
      final clampedT = ymin.clamp(0.0, 1.0);
      final clampedR = xmax.clamp(0.0, 1.0);
      final clampedB = ymax.clamp(0.0, 1.0);
      if (clampedR - clampedL <= 0.008 || clampedB - clampedT <= 0.008) {
        continue;
      }

      final orig = ((item['originalText'] as String?) ?? '').trim();
      final trans = ((item['koreanTranslation'] as String?) ?? '').trim();
      if (trans.isEmpty) continue;

      final bgColor = _parseHexColor((item['bgColorHex'] as String?) ?? '');
      final textColor = bgColor.computeLuminance() > 0.45
          ? const Color(0xFF141414)
          : const Color(0xFFF5F5F5);

      results.add(
        TranslatedBubble(
          normalizedRect: Rect.fromLTRB(clampedL, clampedT, clampedR, clampedB),
          originalText: orig.isNotEmpty ? orig : trans,
          translatedText: trans,
          backgroundColor: bgColor,
          textColor: textColor,
          isVerticalSource: item['isVertical'] as bool? ?? false,
        ),
      );
    }

    return results;
  }

  static Color _parseHexColor(String raw) {
    var hex = raw.trim().replaceFirst('#', '').toUpperCase();
    if (hex.length == 3) {
      hex = '${hex[0]}${hex[0]}${hex[1]}${hex[1]}${hex[2]}${hex[2]}';
    }
    if (hex.length == 6) {
      hex = 'FF$hex';
    }
    if (hex.length == 8) {
      final parsed = int.tryParse(hex, radix: 16);
      if (parsed != null) return Color(parsed);
    }
    return const Color(0xFFFCFCFC);
  }

  static String _stripMarkdownJsonFence(String text) {
    if (!text.startsWith('```')) return text;
    final lines = text.split('\n');
    if (lines.length >= 2 && lines.first.startsWith('```')) {
      lines.removeAt(0);
    }
    if (lines.isNotEmpty && lines.last.trim() == '```') {
      lines.removeLast();
    }
    return lines.join('\n').trim();
  }

  CloudVisionException _classifyDioException(DioException e) {
    final statusCode = e.response?.statusCode;
    final rawData = e.response?.data;
    String? apiErrorMsg;
    if (rawData is Map<String, dynamic>) {
      final err = rawData['error'];
      if (err is Map<String, dynamic>) {
        apiErrorMsg = err['message'] as String?;
      }
    }
    final upperBody = (rawData?.toString() ?? '').toUpperCase();

    if (statusCode == 429 ||
        upperBody.contains('RESOURCE_EXHAUSTED') ||
        upperBody.contains('QUOTA')) {
      return CloudVisionException(
        CloudVisionErrorType.quotaExceeded,
        'Gemini API 할당량(Quota)을 초과했습니다. 잠시 후 다시 시도해 주세요.',
        statusCode: statusCode,
      );
    }

    if (statusCode == 401 ||
        statusCode == 403 ||
        upperBody.contains('API_KEY_INVALID') ||
        upperBody.contains('PERMISSION_DENIED')) {
      return CloudVisionException(
        CloudVisionErrorType.invalidApiKey,
        'Gemini API Key가 유효하지 않습니다. 설정에서 키를 확인해 주세요.',
        statusCode: statusCode,
      );
    }

    if (statusCode != null && statusCode >= 400 && statusCode < 500) {
      final detail = apiErrorMsg != null && apiErrorMsg.isNotEmpty
          ? ' ($apiErrorMsg)'
          : '';
      return CloudVisionException(
        CloudVisionErrorType.invalidResponse,
        'Gemini API 요청 오류 (HTTP $statusCode)$detail',
        statusCode: statusCode,
      );
    }

    return CloudVisionException(
      CloudVisionErrorType.networkError,
      '네트워크 연결이 원활하지 않아 클라우드 번역을 건너뛰고 원본을 표시합니다.',
      statusCode: statusCode,
    );
  }

  @override
  Future<void> dispose() async {
    try {
      _activeCancelToken?.cancel('Engine disposed');
    } catch (_) {}
    _activeCancelToken = null;
  }
}
