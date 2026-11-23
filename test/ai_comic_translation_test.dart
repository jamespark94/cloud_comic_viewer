import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:cloud_comic_viewer/models/ai_translation/page_translation_result.dart';
import 'package:cloud_comic_viewer/models/ai_translation/translated_bubble.dart';
import 'package:cloud_comic_viewer/models/comic_page.dart';
import 'package:cloud_comic_viewer/models/viewer_settings.dart';
import 'package:cloud_comic_viewer/services/ai_translation/bubble_clusterer.dart';
import 'package:cloud_comic_viewer/services/ai_translation/bubble_color_sampler.dart';
import 'package:cloud_comic_viewer/services/ai_translation/comic_translation_cache.dart';
import 'package:cloud_comic_viewer/services/ai_translation/comic_translation_key_storage.dart';
import 'package:cloud_comic_viewer/services/ai_translation/comic_translation_service.dart';
import 'package:cloud_comic_viewer/services/ai_translation/comic_translator_engine.dart';
import 'package:cloud_comic_viewer/services/ai_translation/engines/cloud_vision_comic_translator.dart';
import 'package:cloud_comic_viewer/services/ai_translation/engines/free_google_comic_translator.dart';
import 'package:cloud_comic_viewer/services/ai_translation/engines/on_device_comic_translator.dart';
import 'package:cloud_comic_viewer/services/ai_translation/engines/platform_translator_factory.dart';
import 'package:cloud_comic_viewer/ui/widgets/comic_translation_overlay.dart';

class _FakeComicTranslatorEngine implements ComicTranslatorEngine {
  final List<int> translatedPageIndices = [];
  int initializeCount = 0;
  int disposeCount = 0;

  @override
  String get engineId => 'fake_test_engine';

  @override
  String get displayName => 'Fake Test Engine';

  @override
  bool get isSupported => true;

  @override
  String? get unsupportedReason => null;

  @override
  Future<void> initialize({required ComicSourceLanguage sourceLanguage}) async {
    initializeCount++;
  }

  @override
  Future<List<TranslatedBubble>> translatePage(
    ComicPageTranslationRequest request,
  ) async {
    translatedPageIndices.add(request.pageIndex);
    return [
      TranslatedBubble(
        normalizedRect: const Rect.fromLTRB(0.1, 0.2, 0.4, 0.5),
        originalText: 'テスト${request.pageIndex}',
        translatedText: '테스트${request.pageIndex}',
      ),
    ];
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
  }
}

class _FakeFailingCloudEngine implements ComicTranslatorEngine {
  final CloudVisionException exceptionToThrow;

  _FakeFailingCloudEngine(this.exceptionToThrow);

  @override
  String get engineId => 'fake_cloud_failing';

  @override
  String get displayName => 'Fake Cloud Failing';

  @override
  bool get isSupported => true;

  @override
  String? get unsupportedReason => null;

  @override
  Future<void> initialize({required ComicSourceLanguage sourceLanguage}) async {}

  @override
  Future<List<TranslatedBubble>> translatePage(
    ComicPageTranslationRequest request,
  ) async {
    throw exceptionToThrow;
  }

  @override
  Future<void> dispose() async {}
}

/// 1x1 유효 PNG 바이트 생성 (ImageDimensionUtils 파싱 통과용)
Uint8List _minimalPng10x10() {
  return Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR chunk
    0x00, 0x00, 0x00, 0x0A, // width = 10
    0x00, 0x00, 0x00, 0x0A, // height = 10
    0x08, 0x06, 0x00, 0x00, 0x00, 0x8D, 0x32, 0xCF, 0xBD,
  ]);
}

void main() {
  group('ViewerSettings translation serialization', () {
    test('defaults to OFF and freeGoogle recommended engine with backward compatibility', () {
      const defaults = ViewerSettings();
      expect(defaults.translationMode, ComicTranslationMode.off);
      expect(defaults.translationEngineType, ComicTranslationEngineType.freeGoogle);
      expect(defaults.translationSourceLang, ComicSourceLanguage.auto);

      final legacy = ViewerSettings.fromJson({'keepScreenOn': false});
      expect(legacy.translationMode, ComicTranslationMode.off);
      expect(legacy.translationEngineType, ComicTranslationEngineType.freeGoogle);
      expect(legacy.translationSourceLang, ComicSourceLanguage.auto);

      final updated = defaults.copyWith(
        translationMode: ComicTranslationMode.auto,
        translationEngineType: ComicTranslationEngineType.cloudVision,
        translationSourceLang: ComicSourceLanguage.japanese,
      );
      final restored = ViewerSettings.fromJson(updated.toJson());
      expect(restored.translationMode, ComicTranslationMode.auto);
      expect(
        restored.translationEngineType,
        ComicTranslationEngineType.cloudVision,
      );
      expect(restored.translationSourceLang, ComicSourceLanguage.japanese);
    });
  });

  group('BubbleClusterer', () {
    test('merges vertical Japanese columns right-to-left and filters noise', () {
      final lines = [
        // 오른쪽 첫 번째 세로줄 (먼저 읽어야 함)
        const OcrTextLine(
          text: '今日',
          boundingBox: Rect.fromLTRB(540, 100, 570, 220),
        ),
        // 왼쪽 두 번째 세로줄 (나중에 읽어야 함)
        const OcrTextLine(
          text: '行くぞ',
          boundingBox: Rect.fromLTRB(500, 105, 530, 230),
        ),
        // 노이즈 (순수 기호 & 극소 크기)
        const OcrTextLine(
          text: '...!',
          boundingBox: Rect.fromLTRB(100, 100, 130, 150),
        ),
        const OcrTextLine(
          text: 'a',
          boundingBox: Rect.fromLTRB(10, 10, 13, 14),
        ),
      ];

      final clustered = BubbleClusterer.clusterLines(
        lines: lines,
        imageWidth: 1000,
        imageHeight: 1400,
        preferVerticalRtl: true,
      );

      expect(clustered.length, 1);
      expect(clustered.first.mergedText, '今日行くぞ');
      expect(clustered.first.isVertical, isTrue);
      expect(clustered.first.normalizedRect.left, inInclusiveRange(0.45, 0.55));
      expect(clustered.first.normalizedRect.right, inInclusiveRange(0.55, 0.62));
    });

    test('merges horizontal English lines top-to-bottom', () {
      final lines = [
        const OcrTextLine(
          text: 'Hello',
          boundingBox: Rect.fromLTRB(100, 200, 220, 224),
        ),
        const OcrTextLine(
          text: 'world!',
          boundingBox: Rect.fromLTRB(105, 230, 225, 254),
        ),
      ];

      final clustered = BubbleClusterer.clusterLines(
        lines: lines,
        imageWidth: 800,
        imageHeight: 1200,
        preferVerticalRtl: false,
      );

      expect(clustered.length, 1);
      expect(clustered.first.mergedText, 'Hello world!');
      expect(clustered.first.isVertical, isFalse);
    });

    test('joins horizontal Japanese/Chinese without spaces and Spanish with spaces', () {
      // 가로쓰기 일본어 (구두점 경계 + 내부 줄바꿈 포함) -> 공백 없이 연결
      final jpLines = [
        const OcrTextLine(
          text: '待って、\n本当に',
          boundingBox: Rect.fromLTRB(100, 100, 260, 130),
        ),
        const OcrTextLine(
          text: '「行くよ！」',
          boundingBox: Rect.fromLTRB(105, 136, 255, 166),
        ),
      ];
      final jpClustered = BubbleClusterer.clusterLines(
        lines: jpLines,
        imageWidth: 800,
        imageHeight: 1200,
        preferVerticalRtl: false,
        sourceLanguage: ComicSourceLanguage.japanese,
      );
      expect(jpClustered.length, 1);
      expect(jpClustered.first.mergedText, '待って、本当に「行くよ！」');

      // 가로쓰기 중국어 -> 공백 없이 연결
      final zhLines = [
        const OcrTextLine(
          text: '你 好，',
          boundingBox: Rect.fromLTRB(100, 200, 220, 230),
        ),
        const OcrTextLine(
          text: '准备好了吗？',
          boundingBox: Rect.fromLTRB(100, 236, 240, 266),
        ),
      ];
      final zhClustered = BubbleClusterer.clusterLines(
        lines: zhLines,
        imageWidth: 800,
        imageHeight: 1200,
        preferVerticalRtl: false,
        sourceLanguage: ComicSourceLanguage.chinese,
      );
      expect(zhClustered.length, 1);
      expect(zhClustered.first.mergedText, '你好，准备好了吗？');

      // 스페인어 (특수문자 ¡¿ 및 악센트 포함) -> 공백 연결
      final esLines = [
        const OcrTextLine(
          text: '¡Hola,',
          boundingBox: Rect.fromLTRB(100, 300, 200, 326),
        ),
        const OcrTextLine(
          text: '¿cómo estás?',
          boundingBox: Rect.fromLTRB(102, 332, 240, 358),
        ),
      ];
      final esClustered = BubbleClusterer.clusterLines(
        lines: esLines,
        imageWidth: 800,
        imageHeight: 1200,
        preferVerticalRtl: false,
      );
      expect(esClustered.length, 1);
      expect(esClustered.first.mergedText, '¡Hola, ¿cómo estás?');
    });

    test('sorts multi-column vertical Japanese strictly right-to-left (largest X first) and top-to-bottom', () {
      final lines = [
        // 가장 왼쪽 열 (3번째로 읽어야 함)
        const OcrTextLine(
          text: '天気だ',
          boundingBox: Rect.fromLTRB(480, 110, 510, 230),
        ),
        // 가장 오른쪽 열 상단 (1번째)
        const OcrTextLine(
          text: '今日',
          boundingBox: Rect.fromLTRB(580, 100, 610, 180),
        ),
        // 가장 오른쪽 열 하단 (2번째)
        const OcrTextLine(
          text: 'は',
          boundingBox: Rect.fromLTRB(582, 186, 610, 214),
        ),
        // 가운데 열 (2번째 열)
        const OcrTextLine(
          text: 'いい',
          boundingBox: Rect.fromLTRB(530, 105, 560, 195),
        ),
      ];

      // preferVerticalRtl이 false여도 일본어 세로쓰기 열이면 우->좌 정렬
      final clustered = BubbleClusterer.clusterLines(
        lines: lines,
        imageWidth: 1000,
        imageHeight: 1400,
        preferVerticalRtl: false,
      );

      expect(clustered.length, 1);
      expect(clustered.first.isVertical, isTrue);
      expect(clustered.first.mergedText, '今日はいい天気だ');
    });

    test('cleans OCR symbol artifacts and standalone single-character noise while preserving valid text', () {
      final lines = [
        // 말풍선 테두리/기호 노이즈가 섞인 일본어 라인 + 옆에 붙은 단일 ASCII 노이즈
        const OcrTextLine(
          text: '| ■ 今日',
          boundingBox: Rect.fromLTRB(540, 100, 570, 200),
        ),
        const OcrTextLine(
          text: '行くぞ □',
          boundingBox: Rect.fromLTRB(500, 105, 530, 210),
        ),
        const OcrTextLine(
          text: 'l',
          boundingBox: Rect.fromLTRB(480, 110, 492, 160),
        ),
        // 6x6보다 큰 독립 단일 ASCII 노이즈 -> 제거되어야 함
        const OcrTextLine(
          text: 'a',
          boundingBox: Rect.fromLTRB(100, 100, 116, 120),
        ),
        // 기호 노이즈만 남은 라인 -> 제거되어야 함
        const OcrTextLine(
          text: '| ■ --- • |',
          boundingBox: Rect.fromLTRB(200, 200, 260, 230),
        ),
        // 정상 1글자 일본어 말풍선은 보존
        const OcrTextLine(
          text: 'え',
          boundingBox: Rect.fromLTRB(300, 400, 330, 430),
        ),
      ];

      final clustered = BubbleClusterer.clusterLines(
        lines: lines,
        imageWidth: 1000,
        imageHeight: 1400,
        preferVerticalRtl: true,
      );

      expect(clustered.length, 2);
      expect(clustered[0].mergedText, '今日行くぞ');
      expect(clustered[1].mergedText, 'え');

      // 영어 문장 내의 단독 라인 'I'는 주변 라인과 병합되어 보존되어야 함
      final enLines = [
        const OcrTextLine(
          text: 'I',
          boundingBox: Rect.fromLTRB(100, 100, 120, 124),
        ),
        const OcrTextLine(
          text: 'know!',
          boundingBox: Rect.fromLTRB(100, 130, 200, 154),
        ),
      ];
      final enClustered = BubbleClusterer.clusterLines(
        lines: enLines,
        imageWidth: 800,
        imageHeight: 1200,
        preferVerticalRtl: false,
      );
      expect(enClustered.length, 1);
      expect(enClustered.first.mergedText, 'I know!');
    });
  });

  group('BubbleColorSampler', () {
    test('detects light bubble background and dark text color', () {
      const w = 40;
      const h = 40;
      final rgba = Uint8List(w * h * 4);
      for (int i = 0; i < w * h; i++) {
        rgba[i * 4] = 250;
        rgba[i * 4 + 1] = 250;
        rgba[i * 4 + 2] = 250;
        rgba[i * 4 + 3] = 255;
      }

      final colors = BubbleColorSampler.sampleFromRgbaBytes(
        rgba,
        w,
        h,
        const Rect.fromLTRB(0.1, 0.1, 0.9, 0.9),
      );

      expect(colors.backgroundColor.computeLuminance(), greaterThan(0.8));
      expect(colors.textColor.computeLuminance(), lessThan(0.2));
    });

    test('detects dark narration box background and light text color', () {
      const w = 40;
      const h = 40;
      final rgba = Uint8List(w * h * 4);
      for (int i = 0; i < w * h; i++) {
        rgba[i * 4] = 15;
        rgba[i * 4 + 1] = 15;
        rgba[i * 4 + 2] = 15;
        rgba[i * 4 + 3] = 255;
      }

      final colors = BubbleColorSampler.sampleFromRgbaBytes(
        rgba,
        w,
        h,
        const Rect.fromLTRB(0.1, 0.1, 0.9, 0.9),
      );

      expect(colors.backgroundColor.computeLuminance(), lessThan(0.2));
      expect(colors.textColor.computeLuminance(), greaterThan(0.8));
    });
  });

  group('ComicTranslationOverlay projection', () {
    test('projects normalized rects accurately for splitLeftHalf and splitRightHalf', () {
      const leftBubble = Rect.fromLTRB(0.1, 0.2, 0.4, 0.4);
      const rightBubble = Rect.fromLTRB(0.6, 0.3, 0.9, 0.5);

      final leftInLeftView = ComicTranslationOverlay.projectNormalizedRect(
        leftBubble,
        ComicOverlayViewportMode.splitLeftHalf,
      );
      expect(leftInLeftView, isNotNull);
      expect(leftInLeftView!.left, closeTo(0.2, 0.001));
      expect(leftInLeftView.right, closeTo(0.8, 0.001));

      expect(
        ComicTranslationOverlay.projectNormalizedRect(
          rightBubble,
          ComicOverlayViewportMode.splitLeftHalf,
        ),
        isNull,
      );

      final rightInRightView = ComicTranslationOverlay.projectNormalizedRect(
        rightBubble,
        ComicOverlayViewportMode.splitRightHalf,
      );
      expect(rightInRightView, isNotNull);
      expect(rightInRightView!.left, closeTo(0.2, 0.001));
      expect(rightInRightView.right, closeTo(0.8, 0.001));
    });
  });

  group('ComicTranslationCache & Service', () {
    test('persists and retrieves bubbles from L1 & L2 cache without re-translation', () async {
      final tempDir = await Directory.systemTemp.createTemp('comic_trans_test_');
      try {
        final cache = ComicTranslationCache(
          cacheDirProvider: () async => tempDir,
        );

        final result = PageTranslationResult(
          bookId: 'gdrive:book1',
          pageIndex: 3,
          sourceLanguage: ComicSourceLanguage.japanese,
          engineId: 'test',
          bubbles: const [
            TranslatedBubble(
              normalizedRect: Rect.fromLTRB(0.2, 0.3, 0.5, 0.6),
              originalText: 'おはよう',
              translatedText: '좋은 아침',
              isVerticalSource: true,
            ),
          ],
          createdAt: DateTime(2026, 11, 23),
        );

        await cache.put(result);
        cache.clearMemory();

        final loaded = await cache.get(
          'gdrive:book1',
          3,
          ComicSourceLanguage.japanese,
        );
        expect(loaded, isNotNull);
        expect(loaded!.bubbles.length, 1);
        expect(loaded.bubbles.first.translatedText, '좋은 아침');
        expect(loaded.bubbles.first.isVerticalSource, isTrue);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('auto mode translates current page + pre-fetches next 2 pages once', () async {
      final tempDir = await Directory.systemTemp.createTemp('comic_svc_test_');
      try {
        final fakeEngine = _FakeComicTranslatorEngine();
        final cache = ComicTranslationCache(
          cacheDirProvider: () async => tempDir,
        );
        final service = ComicTranslationService.forTesting(
          engine: fakeEngine,
          cache: cache,
        );

        final png = _minimalPng10x10();
        final pages = List.generate(
          5,
          (i) => ComicPage(index: i, name: '$i.png', initialBytes: png),
        );

        await service.onPagesVisible(
          bookId: 'book_auto_1',
          visiblePages: [pages[0]],
          allPages: pages,
          mode: ComicTranslationMode.auto,
          sourceLanguage: ComicSourceLanguage.japanese,
          isRightToLeftManga: true,
        );

        // 비동기 직렬 워커가 현재 페이지(0) + Pre-fetch(1, 2)를 처리할 때까지 잠시 대기
        await Future<void>.delayed(const Duration(milliseconds: 120));

        expect(fakeEngine.translatedPageIndices, [0, 1, 2]);
        expect(
          service.getCachedBubblesSync('book_auto_1', 0, ComicSourceLanguage.japanese)?.first.translatedText,
          '테스트0',
        );
        expect(
          service.getCachedBubblesSync('book_auto_1', 2, ComicSourceLanguage.japanese)?.first.translatedText,
          '테스트2',
        );

        // 페이지 1로 이동 시 이미 캐시된 1, 2는 재번역하지 않고 3만 추가 Pre-fetch
        await service.onPagesVisible(
          bookId: 'book_auto_1',
          visiblePages: [pages[1]],
          allPages: pages,
          mode: ComicTranslationMode.auto,
          sourceLanguage: ComicSourceLanguage.japanese,
          isRightToLeftManga: true,
        );
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(fakeEngine.translatedPageIndices, [0, 1, 2, 3]);

        // 눈 아이콘 토글 확인
        expect(service.isOverlayVisible, isTrue);
        service.toggleOverlayVisibility();
        expect(service.isOverlayVisible, isFalse);

        await service.onViewerDisposed('book_auto_1');
        expect(fakeEngine.disposeCount, 1);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('platform factory returns safe Stub on Windows desktop', () {
      if (Platform.isWindows) {
        final engine = createDefaultOnDeviceEngine();
        expect(engine.isSupported, isFalse);
        expect(engine.unsupportedReason, isNotNull);
      }
    });
  });

  group('Phase 2 CloudVisionComicTranslator & Traffic Defense', () {
    test('prepareImageForVisionApi resizes oversized image to maxDimension JPEG', () {
      final large = img.Image(width: 2400, height: 3200);
      img.fill(large, color: img.ColorRgb8(245, 245, 245));
      final pngBytes = Uint8List.fromList(img.encodePng(large));

      final prepared = CloudVisionComicTranslator.prepareImageForVisionApi(
        pngBytes,
        maxDimension: 1440,
        jpegQuality: 80,
      );

      expect(prepared.mimeType, 'image/jpeg');
      final decoded = img.decodeJpg(prepared.bytes);
      expect(decoded, isNotNull);
      expect(decoded!.height, 1440);
      expect(decoded.width, 1080);
    });

    test('buildGeminiRequestBody & parseGeminiResponse handle structured output and hex colors', () {
      final body = CloudVisionComicTranslator.buildGeminiRequestBody(
        base64Image: 'AAEC',
        mimeType: 'image/jpeg',
        sourceLanguage: ComicSourceLanguage.japanese,
        isRightToLeftManga: true,
      );

      final genConfig = body['generationConfig'] as Map<String, dynamic>;
      expect(genConfig['responseMimeType'], 'application/json');
      expect(genConfig['responseSchema'], isA<Map<String, dynamic>>());

      final responseJson = {
        'candidates': [
          {
            'content': {
              'parts': [
                {
                  'text': '''```json
{
  "bubbles": [
    {
      "ymin": 0.1,
      "xmin": 0.6,
      "ymax": 0.3,
      "xmax": 0.9,
      "bgColorHex": "#FFFFFF",
      "originalText": "マジかよ！",
      "koreanTranslation": "진짜냐고!",
      "isVertical": true
    },
    {
      "ymin": 400,
      "xmin": 100,
      "ymax": 600,
      "xmax": 400,
      "bgColorHex": "#141414",
      "originalText": "その時…",
      "koreanTranslation": "그때...",
      "isVertical": false
    }
  ]
}
```'''
                }
              ]
            }
          }
        ]
      };

      final bubbles = CloudVisionComicTranslator.parseGeminiResponse(responseJson);
      expect(bubbles.length, 2);

      expect(bubbles[0].normalizedRect.top, closeTo(0.1, 0.001));
      expect(bubbles[0].normalizedRect.left, closeTo(0.6, 0.001));
      expect(bubbles[0].koreanTranslationOrNull ?? bubbles[0].translatedText, '진짜냐고!');
      expect(bubbles[0].backgroundColor.computeLuminance(), greaterThan(0.9));
      expect(bubbles[0].textColor.computeLuminance(), lessThan(0.2));
      expect(bubbles[0].isVerticalSource, isTrue);

      // 0~1000 스케일도 자동 정규화되는지 검증
      expect(bubbles[1].normalizedRect.top, closeTo(0.4, 0.001));
      expect(bubbles[1].normalizedRect.left, closeTo(0.1, 0.001));
      expect(bubbles[1].normalizedRect.bottom, closeTo(0.6, 0.001));
      expect(bubbles[1].normalizedRect.right, closeTo(0.4, 0.001));
      expect(bubbles[1].backgroundColor.computeLuminance(), lessThan(0.1));
      expect(bubbles[1].textColor.computeLuminance(), greaterThan(0.8));
    });

    test('cache separates onDevice and cloudVision results for same page', () async {
      final tempDir = await Directory.systemTemp.createTemp('comic_dual_cache_');
      try {
        final cache = ComicTranslationCache(
          cacheDirProvider: () async => tempDir,
        );

        await cache.put(PageTranslationResult(
          bookId: 'book_dual',
          pageIndex: 0,
          sourceLanguage: ComicSourceLanguage.japanese,
          engineType: ComicTranslationEngineType.onDevice,
          engineId: 'on_device',
          bubbles: const [
            TranslatedBubble(
              normalizedRect: Rect.fromLTRB(0.1, 0.1, 0.3, 0.3),
              originalText: 'orig',
              translatedText: '로컬번역',
            ),
          ],
          createdAt: DateTime(2026, 11, 23),
        ));

        await cache.put(PageTranslationResult(
          bookId: 'book_dual',
          pageIndex: 0,
          sourceLanguage: ComicSourceLanguage.japanese,
          engineType: ComicTranslationEngineType.cloudVision,
          engineId: 'cloud_vision',
          bubbles: const [
            TranslatedBubble(
              normalizedRect: Rect.fromLTRB(0.1, 0.1, 0.3, 0.3),
              originalText: 'orig',
              translatedText: '클라우드고품질번역',
            ),
          ],
          createdAt: DateTime(2026, 11, 23),
        ));

        cache.clearMemory();
        final local = await cache.get(
          'book_dual',
          0,
          ComicSourceLanguage.japanese,
          engineType: ComicTranslationEngineType.onDevice,
        );
        final cloud = await cache.get(
          'book_dual',
          0,
          ComicSourceLanguage.japanese,
          engineType: ComicTranslationEngineType.cloudVision,
        );

        expect(local?.bubbles.first.translatedText, '로컬번역');
        expect(cloud?.bubbles.first.translatedText, '클라우드고품질번역');
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('cloud auto mode debounces rapid page flips and avoids duplicate API calls', () async {
      final tempDir = await Directory.systemTemp.createTemp('comic_cloud_deb_');
      try {
        expect(
          ComicTranslationService.defaultCloudAutoDebounceDuration,
          const Duration(milliseconds: 1200),
        );

        final fakeCloud = _FakeComicTranslatorEngine();
        final cache = ComicTranslationCache(
          cacheDirProvider: () async => tempDir,
        );
        final service = ComicTranslationService.forTesting(
          cloudEngine: fakeCloud,
          cache: cache,
          keyStorage: ComicTranslationKeyStorage.inMemory(initialKey: 'AIzaTest123456'),
          cloudAutoDebounceDuration: const Duration(milliseconds: 120),
        );

        final png = _minimalPng10x10();
        final pages = List.generate(
          5,
          (i) => ComicPage(index: i, name: '$i.png', initialBytes: png),
        );

        // 빠르게 0 -> 1 -> 2 페이지로 넘김 (각 체류시간 30ms < 디바운스 120ms)
        await service.onPagesVisible(
          bookId: 'cloud_book',
          visiblePages: [pages[0]],
          allPages: pages,
          mode: ComicTranslationMode.auto,
          sourceLanguage: ComicSourceLanguage.japanese,
          isRightToLeftManga: true,
          engineType: ComicTranslationEngineType.cloudVision,
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));

        await service.onPagesVisible(
          bookId: 'cloud_book',
          visiblePages: [pages[1]],
          allPages: pages,
          mode: ComicTranslationMode.auto,
          sourceLanguage: ComicSourceLanguage.japanese,
          isRightToLeftManga: true,
          engineType: ComicTranslationEngineType.cloudVision,
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));

        await service.onPagesVisible(
          bookId: 'cloud_book',
          visiblePages: [pages[2]],
          allPages: pages,
          mode: ComicTranslationMode.auto,
          sourceLanguage: ComicSourceLanguage.japanese,
          isRightToLeftManga: true,
          engineType: ComicTranslationEngineType.cloudVision,
        );

        // 아직 디바운스 대기 중이므로 0회 호출
        expect(fakeCloud.translatedPageIndices, isEmpty);

        // 체류 후 디바운스 만료 -> 페이지 2(+ 다음 1페이지 3 Pre-fetch)만 호출되고 0, 1은 스킵
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(fakeCloud.translatedPageIndices, [2, 3]);

        // 이미 캐싱된 페이지 2로 되돌아와도 재호출 없음
        await service.onPagesVisible(
          bookId: 'cloud_book',
          visiblePages: [pages[2]],
          allPages: pages,
          mode: ComicTranslationMode.auto,
          sourceLanguage: ComicSourceLanguage.japanese,
          isRightToLeftManga: true,
          engineType: ComicTranslationEngineType.cloudVision,
        );
        await Future<void>.delayed(const Duration(milliseconds: 180));
        expect(fakeCloud.translatedPageIndices, [2, 3]);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('cloud quota/network error emits notice safely without crashing', () async {
      final tempDir = await Directory.systemTemp.createTemp('comic_cloud_err_');
      try {
        final failingCloud = _FakeFailingCloudEngine(
          const CloudVisionException(
            CloudVisionErrorType.quotaExceeded,
            'Gemini API 할당량(Quota)을 초과했습니다.',
            statusCode: 429,
          ),
        );
        final service = ComicTranslationService.forTesting(
          cloudEngine: failingCloud,
          cache: ComicTranslationCache(cacheDirProvider: () async => tempDir),
          keyStorage: ComicTranslationKeyStorage.inMemory(initialKey: 'AIzaTest123456'),
        );

        final page = ComicPage(
          index: 0,
          name: '0.png',
          initialBytes: _minimalPng10x10(),
        );

        final msg = await service.translatePagesNow(
          bookId: 'err_book',
          visiblePages: [page],
          sourceLanguage: ComicSourceLanguage.japanese,
          isRightToLeftManga: true,
          engineType: ComicTranslationEngineType.cloudVision,
        );

        expect(msg, contains('할당량'));
        expect(service.isTranslatingAny, isFalse);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('ComicTranslationKeyStorage masks and manages API keys in memory', () async {
      final storage = ComicTranslationKeyStorage.inMemory();
      expect(storage.hasCachedApiKey, isFalse);

      await storage.saveApiKey('AIzaSyDummyKey12345678');
      expect(storage.hasCachedApiKey, isTrue);
      expect(await storage.loadApiKey(), 'AIzaSyDummyKey12345678');
      expect(
        ComicTranslationKeyStorage.maskApiKey(storage.cachedApiKey),
        'AIza••••5678',
      );

      await storage.deleteApiKey();
      expect(storage.hasCachedApiKey, isFalse);
    });
  });

  group('FreeGoogleComicTranslator hybrid pipeline & fallback', () {
    test('batches multiple bubbles into a single HTTP GET request with delimiter', () async {
      final recordedRequests = <RequestOptions>[];
      final dio = Dio();
      dio.httpClientAdapter = _MockHttpClientAdapter((options) async {
        recordedRequests.add(options);
        final payload = jsonEncode([
          [
            ['안녕!\n', 'Hello!\n', null, null],
            ['|||\n', '|||\n', null, null],
            ['오늘 날씨가 좋네', 'Nice weather today', null, null],
          ],
          null,
          'en',
        ]);
        return ResponseBody.fromString(
          payload,
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });

      final extractorCalls = <int>[];
      final engine = FreeGoogleComicTranslator(
        dio: dio,
        isSupportedOverride: true,
        bubbleExtractor: (request) async {
          extractorCalls.add(request.pageIndex);
          return const [
            ExtractedBubbleCandidate(
              cluster: ClusteredBubble(
                pixelRect: Rect.fromLTRB(10, 10, 100, 50),
                normalizedRect: Rect.fromLTRB(0.1, 0.1, 0.5, 0.25),
                mergedText: 'Hello!',
                isVertical: false,
              ),
              colors: BubbleColors(
                backgroundColor: Color(0xFFFCFCFC),
                textColor: Color(0xFF141414),
              ),
              detectedLanguageCode: 'en',
            ),
            ExtractedBubbleCandidate(
              cluster: ClusteredBubble(
                pixelRect: Rect.fromLTRB(10, 60, 100, 100),
                normalizedRect: Rect.fromLTRB(0.2, 0.4, 0.8, 0.6),
                mergedText: '이미 한국어',
                isVertical: false,
              ),
              colors: BubbleColors(
                backgroundColor: Color(0xFFFCFCFC),
                textColor: Color(0xFF141414),
              ),
              detectedLanguageCode: 'ko',
            ),
            ExtractedBubbleCandidate(
              cluster: ClusteredBubble(
                pixelRect: Rect.fromLTRB(10, 110, 100, 160),
                normalizedRect: Rect.fromLTRB(0.3, 0.7, 0.9, 0.9),
                mergedText: 'Nice weather today',
                isVertical: true,
              ),
              colors: BubbleColors(
                backgroundColor: Color(0xFF141414),
                textColor: Color(0xFFF5F5F5),
              ),
              detectedLanguageCode: 'en',
            ),
          ];
        },
      );

      final bubbles = await engine.translatePage(
        ComicPageTranslationRequest(
          bookId: 'free_book',
          pageIndex: 0,
          imageBytes: _minimalPng10x10(),
          imageWidth: 200,
          imageHeight: 200,
          sourceLanguage: ComicSourceLanguage.english,
          targetLanguage: 'ko',
          isRightToLeftManga: false,
        ),
      );

      expect(extractorCalls, [0]);
      // 페이지당 정확히 1회의 HTTP GET 요청만 수행
      expect(recordedRequests.length, 1);
      final req = recordedRequests.first;
      expect(req.method, 'GET');
      expect(req.uri.host, 'translate.googleapis.com');
      expect(req.uri.path, '/translate_a/single');
      expect(req.queryParameters['client'], 'gtx');
      expect(req.queryParameters['sl'], 'en');
      expect(req.queryParameters['tl'], 'ko');
      expect(
        req.queryParameters['q'],
        'Hello!${FreeGoogleComicTranslator.batchDelimiter}Nice weather today',
      );

      // 한국어 말풍선은 건너뛰고 번역 대상 2개만 좌표와 매핑
      expect(bubbles.length, 2);
      expect(bubbles[0].normalizedRect, const Rect.fromLTRB(0.1, 0.1, 0.5, 0.25));
      expect(bubbles[0].originalText, 'Hello!');
      expect(bubbles[0].translatedText, '안녕!');
      expect(bubbles[0].isVerticalSource, isFalse);

      expect(bubbles[1].normalizedRect, const Rect.fromLTRB(0.3, 0.7, 0.9, 0.9));
      expect(bubbles[1].originalText, 'Nice weather today');
      expect(bubbles[1].translatedText, '오늘 날씨가 좋네');
      expect(bubbles[1].backgroundColor, const Color(0xFF141414));
      expect(bubbles[1].textColor, const Color(0xFFF5F5F5));
      expect(bubbles[1].isVerticalSource, isTrue);
      expect(engine.lastRunUsedFallback, isFalse);
    });

    test('falls back automatically to offline engine when network fails or rate-limited', () async {
      final dio = Dio();
      dio.httpClientAdapter = _MockHttpClientAdapter((options) async {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
          message: 'SocketException: Network is unreachable',
        );
      });

      final offlineFallback = _FakeComicTranslatorEngine();
      final notices = <String>[];
      final engine = FreeGoogleComicTranslator(
        dio: dio,
        isSupportedOverride: true,
        fallbackEngine: offlineFallback,
        onNotice: notices.add,
        bubbleExtractor: (_) async => const [
          ExtractedBubbleCandidate(
            cluster: ClusteredBubble(
              pixelRect: Rect.fromLTRB(10, 10, 80, 80),
              normalizedRect: Rect.fromLTRB(0.1, 0.1, 0.4, 0.4),
              mergedText: 'おはよう',
              isVertical: true,
            ),
            colors: BubbleColors(
              backgroundColor: Colors.white,
              textColor: Color(0xFF141414),
            ),
            detectedLanguageCode: 'ja',
          ),
        ],
      );

      final result = await engine.translatePage(
        ComicPageTranslationRequest(
          bookId: 'offline_book',
          pageIndex: 4,
          imageBytes: _minimalPng10x10(),
          imageWidth: 100,
          imageHeight: 100,
          sourceLanguage: ComicSourceLanguage.japanese,
        ),
      );

      expect(engine.lastRunUsedFallback, isTrue);
      expect(offlineFallback.translatedPageIndices, [4]);
      expect(result.length, 1);
      expect(result.first.translatedText, '테스트4');
      expect(notices, isNotEmpty);
    });

    test('cleans OCR noise and applies language-specific newline joining before batching with |||', () async {
      final recordedRequests = <RequestOptions>[];
      final dio = Dio();
      dio.httpClientAdapter = _MockHttpClientAdapter((options) async {
        recordedRequests.add(options);
        final payload = jsonEncode([
          [
            ['안녕 세계!\n', 'Hello world!\n', null, null],
            ['|||\n', '|||\n', null, null],
            ['오늘 갈게!', '今日行くぞ！', null, null],
          ],
        ]);
        return ResponseBody.fromString(
          payload,
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });

      final engine = FreeGoogleComicTranslator(
        dio: dio,
        isSupportedOverride: true,
        bubbleExtractor: (_) async => const [
          ExtractedBubbleCandidate(
            cluster: ClusteredBubble(
              pixelRect: Rect.fromLTRB(10, 10, 120, 60),
              normalizedRect: Rect.fromLTRB(0.1, 0.1, 0.5, 0.25),
              mergedText: '| ■ Hello\nworld! ||| □',
              isVertical: false,
            ),
            colors: BubbleColors(
              backgroundColor: Colors.white,
              textColor: Color(0xFF141414),
            ),
            detectedLanguageCode: 'en',
          ),
          // 정제 후 노이즈만 남는 후보는 배치에서 제외되어 구분자 매핑이 깨지지 않아야 함
          ExtractedBubbleCandidate(
            cluster: ClusteredBubble(
              pixelRect: Rect.fromLTRB(10, 70, 50, 90),
              normalizedRect: Rect.fromLTRB(0.1, 0.3, 0.2, 0.4),
              mergedText: '| • l ■ |',
              isVertical: false,
            ),
            colors: BubbleColors(
              backgroundColor: Colors.white,
              textColor: Color(0xFF141414),
            ),
            detectedLanguageCode: 'ja',
          ),
          ExtractedBubbleCandidate(
            cluster: ClusteredBubble(
              pixelRect: Rect.fromLTRB(140, 10, 180, 160),
              normalizedRect: Rect.fromLTRB(0.6, 0.1, 0.9, 0.8),
              mergedText: '今日\n行くぞ！ □',
              isVertical: true,
            ),
            colors: BubbleColors(
              backgroundColor: Colors.white,
              textColor: Color(0xFF141414),
            ),
            detectedLanguageCode: 'ja',
          ),
        ],
      );

      final bubbles = await engine.translatePage(
        ComicPageTranslationRequest(
          bookId: 'noise_cleanup_book',
          pageIndex: 0,
          imageBytes: _minimalPng10x10(),
          imageWidth: 200,
          imageHeight: 200,
          sourceLanguage: ComicSourceLanguage.auto,
          targetLanguage: 'ko',
        ),
      );

      expect(recordedRequests.length, 1);
      expect(
        recordedRequests.first.queryParameters['q'],
        'Hello world!${FreeGoogleComicTranslator.batchDelimiter}今日行くぞ！',
      );
      expect(bubbles.length, 2);
      expect(bubbles[0].originalText, 'Hello world!');
      expect(bubbles[0].translatedText, '안녕 세계!');
      expect(bubbles[1].originalText, '今日行くぞ！');
      expect(bubbles[1].translatedText, '오늘 갈게!');
    });

    test('ComicTranslationService routes freeGoogle engineType and isolates cache', () async {
      final tempDir = await Directory.systemTemp.createTemp('comic_free_svc_');
      try {
        final fakeFree = _FakeComicTranslatorEngine();
        final fakeOnDevice = _FakeComicTranslatorEngine();
        final service = ComicTranslationService.forTesting(
          engine: fakeOnDevice,
          freeGoogleEngine: fakeFree,
          cache: ComicTranslationCache(cacheDirProvider: () async => tempDir),
        );

        final page = ComicPage(
          index: 0,
          name: '0.png',
          initialBytes: _minimalPng10x10(),
        );

        await service.translatePagesNow(
          bookId: 'book_hybrid',
          visiblePages: [page],
          sourceLanguage: ComicSourceLanguage.japanese,
          isRightToLeftManga: true,
          engineType: ComicTranslationEngineType.freeGoogle,
        );

        expect(fakeFree.translatedPageIndices, [0]);
        expect(fakeOnDevice.translatedPageIndices, isEmpty);
        expect(
          service.hasCachedResultSync(
            'book_hybrid',
            0,
            ComicSourceLanguage.japanese,
            engineType: ComicTranslationEngineType.freeGoogle,
          ),
          isTrue,
        );
        expect(
          service.hasCachedResultSync(
            'book_hybrid',
            0,
            ComicSourceLanguage.japanese,
            engineType: ComicTranslationEngineType.onDevice,
          ),
          isFalse,
        );
      } finally {
        await tempDir.delete(recursive: true);
      }
    });
  });
}

class _MockHttpClientAdapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions options) handler;

  _MockHttpClientAdapter(this.handler);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) =>
      handler(options);

  @override
  void close({bool force = false}) {}
}

extension on TranslatedBubble {
  String? get koreanTranslationOrNull =>
      translatedText.isEmpty ? null : translatedText;
}
