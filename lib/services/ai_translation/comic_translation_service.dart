import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import '../../models/ai_translation/page_translation_result.dart';
import '../../models/ai_translation/translated_bubble.dart';
import '../../models/comic_page.dart';
import '../../models/viewer_settings.dart';
import '../../utils/image_dimension_utils.dart';
import 'comic_translation_cache.dart';
import 'comic_translation_key_storage.dart';
import 'comic_translator_engine.dart';
import 'engines/cloud_vision_comic_translator.dart';
import 'engines/free_google_comic_translator.dart';
import 'engines/platform_translator_factory.dart';

class _TranslationQueueTask {
  final String bookId;
  final ComicPage page;
  final ComicSourceLanguage sourceLanguage;
  final ComicTranslationEngineType engineType;
  final bool isRightToLeftManga;
  final bool isPrefetch;
  final Completer<PageTranslationResult?>? completer;

  _TranslationQueueTask({
    required this.bookId,
    required this.page,
    required this.sourceLanguage,
    required this.engineType,
    required this.isRightToLeftManga,
    required this.isPrefetch,
    this.completer,
  });

  String get taskKey => ComicTranslationCache.buildKey(
        bookId,
        page.index,
        sourceLanguage,
        engineType: engineType,
      );
}

/// 만화 AI 실시간 말풍선 번역 최상위 오케스트레이터 (Singleton & ChangeNotifier)
///
/// - OFF 모드에서는 엔진을 메모리에 로드하지 않음 (Strict Lazy Initialization)
/// - [로컬 오프라인(ML Kit)], [온라인 무료(로컬 OCR + 구글 번역)], [클라우드 AI(Gemini Vision)] 전략 스위칭 지원
/// - 클라우드 자동 번역 시 페이지 체류 1.2초 이상일 때만 API를 호출(Debouncing)해 트래픽 폭주 방어
/// - Single-Flight 직렬 큐로 동작하여 클라우드 Range 스트리밍 대역폭과 경쟁하지 않음
class ComicTranslationService extends ChangeNotifier {
  static final ComicTranslationService instance =
      ComicTranslationService._internal();

  static const Duration defaultCloudAutoDebounceDuration =
      Duration(milliseconds: 1200);

  ComicTranslationService._internal({
    ComicTranslatorEngine? onDeviceEngine,
    ComicTranslatorEngine? freeGoogleEngine,
    ComicTranslatorEngine? cloudEngine,
    ComicTranslationCache? cache,
    ComicTranslationKeyStorage? keyStorage,
  })  : _cache = cache ?? ComicTranslationCache(),
        _keyStorage = keyStorage ?? ComicTranslationKeyStorage.instance,
        cloudAutoDebounceDuration = defaultCloudAutoDebounceDuration {
    _onDeviceEngine = onDeviceEngine;
    _freeGoogleEngine = freeGoogleEngine;
    _cloudEngine = cloudEngine;
  }

  /// 단위 테스트용 생성자 (격리된 Mock 엔진/저장소/캐시/디바운스 주입 가능)
  @visibleForTesting
  ComicTranslationService.forTesting({
    ComicTranslatorEngine? engine,
    ComicTranslatorEngine? freeGoogleEngine,
    ComicTranslatorEngine? cloudEngine,
    ComicTranslationCache? cache,
    ComicTranslationKeyStorage? keyStorage,
    this.cloudAutoDebounceDuration = defaultCloudAutoDebounceDuration,
  })  : _cache = cache ?? ComicTranslationCache(),
        _keyStorage = keyStorage ?? ComicTranslationKeyStorage.inMemory() {
    _onDeviceEngine = engine;
    _freeGoogleEngine = freeGoogleEngine;
    _cloudEngine = cloudEngine;
  }

  ComicTranslatorEngine? _onDeviceEngine;
  ComicTranslatorEngine? _freeGoogleEngine;
  ComicTranslatorEngine? _cloudEngine;
  final ComicTranslationCache _cache;
  final ComicTranslationKeyStorage _keyStorage;
  final Duration cloudAutoDebounceDuration;

  bool _isOverlayVisible = true;
  ComicTranslationEngineType? _initializedEngineType;
  ComicSourceLanguage? _initializedLang;

  String? _activeBookId;
  final Set<int> _translatingPages = {};
  final Set<String> _queuedOrInFlightKeys = {};
  final Queue<_TranslationQueueTask> _highPriorityQueue = Queue();
  final Queue<_TranslationQueueTask> _prefetchQueue = Queue();
  bool _isWorkerRunning = false;
  bool _notifiedUnsupportedOnce = false;

  Timer? _cloudAutoDebounceTimer;
  int _visibleGeneration = 0;

  String? _latestNoticeMessage;
  int _noticeSequence = 0;
  DateTime? _lastNoticeAt;

  /// 번역 오버레이 표시 여부 (원본/번역 눈 아이콘 토글 상태)
  bool get isOverlayVisible => _isOverlayVisible;

  /// 현재 1개 이상의 페이지가 번역 중인지 여부 (비침습적 마이크로 인디케이터용)
  bool get isTranslatingAny => _translatingPages.isNotEmpty;

  /// 특정 페이지가 현재 번역 중인지 여부
  bool isPageTranslating(int pageIndex) => _translatingPages.contains(pageIndex);

  /// 비동기 번역 중 발생한 가벼운 안내 메시지 및 시퀀스 번호
  String? get latestNoticeMessage => _latestNoticeMessage;
  int get noticeSequence => _noticeSequence;

  /// Gemini API Key 상태 접근자
  bool get hasGeminiApiKey => _keyStorage.hasCachedApiKey;
  String? get maskedGeminiApiKey =>
      ComicTranslationKeyStorage.maskApiKey(_keyStorage.cachedApiKey);

  Future<String?> loadGeminiApiKey({bool forceRefresh = false}) async {
    final key = await _keyStorage.loadApiKey(forceRefresh: forceRefresh);
    notifyListeners();
    return key;
  }

  Future<void> saveGeminiApiKey(String apiKey) async {
    await _keyStorage.saveApiKey(apiKey);
    // 새 API 키 반영을 위해 클라우드 엔진 초기화 플래그 리셋
    if (_initializedEngineType == ComicTranslationEngineType.cloudVision) {
      _initializedEngineType = null;
      _initializedLang = null;
    }
    notifyListeners();
  }

  Future<void> deleteGeminiApiKey() async {
    await _keyStorage.deleteApiKey();
    if (_initializedEngineType == ComicTranslationEngineType.cloudVision) {
      _initializedEngineType = null;
      _initializedLang = null;
    }
    notifyListeners();
  }

  ComicTranslatorEngine _ensureEngineInstance(
    ComicTranslationEngineType engineType,
  ) {
    switch (engineType) {
      case ComicTranslationEngineType.onDevice:
        return _onDeviceEngine ??= createDefaultOnDeviceEngine();
      case ComicTranslationEngineType.freeGoogle:
        _onDeviceEngine ??= createDefaultOnDeviceEngine();
        return _freeGoogleEngine ??= createDefaultFreeGoogleEngine(
          onDeviceEngine: _onDeviceEngine,
          onNotice: _emitNotice,
        );
      case ComicTranslationEngineType.cloudVision:
        return _cloudEngine ??= CloudVisionComicTranslator(
          apiKeyProvider: () => _keyStorage.loadApiKey(),
        );
    }
  }

  /// 지정된 엔진 타입이 현재 환경에서 동작 가능한지 여부
  bool isEngineSupportedFor(ComicTranslationEngineType engineType) {
    if (engineType == ComicTranslationEngineType.cloudVision) {
      if (_cloudEngine != null) return _cloudEngine!.isSupported;
      return _keyStorage.hasCachedApiKey;
    }
    return _ensureEngineInstance(engineType).isSupported;
  }

  String? unsupportedReasonFor(ComicTranslationEngineType engineType) {
    if (engineType == ComicTranslationEngineType.cloudVision) {
      if (_cloudEngine != null) return _cloudEngine!.unsupportedReason;
      return _keyStorage.hasCachedApiKey
          ? null
          : '클라우드 고품질 모드를 사용하려면 설정에서 Gemini API Key를 먼저 입력·저장해 주세요.';
    }
    return _ensureEngineInstance(engineType).unsupportedReason;
  }

  bool get isEngineSupported =>
      isEngineSupportedFor(ComicTranslationEngineType.onDevice);

  String? get unsupportedReason =>
      unsupportedReasonFor(ComicTranslationEngineType.onDevice);

  /// L1 메모리 캐시에서 동기식으로 번역 결과를 조회합니다 (오버레이 0ms 렌더링용).
  List<TranslatedBubble>? getCachedBubblesSync(
    String bookId,
    int pageIndex,
    ComicSourceLanguage sourceLanguage, {
    ComicTranslationEngineType engineType = ComicTranslationEngineType.onDevice,
  }) {
    return _cache
        .getMemory(
          bookId,
          pageIndex,
          sourceLanguage,
          engineType: engineType,
        )
        ?.bubbles;
  }

  /// 특정 페이지에 번역 완료된 말풍선 데이터가 캐시에 있는지 확인합니다.
  bool hasCachedResultSync(
    String bookId,
    int pageIndex,
    ComicSourceLanguage sourceLanguage, {
    ComicTranslationEngineType engineType = ComicTranslationEngineType.onDevice,
  }) {
    final res = _cache.getMemory(
      bookId,
      pageIndex,
      sourceLanguage,
      engineType: engineType,
    );
    return res != null && res.status == PageTranslationStatus.completed;
  }

  /// [원본/번역 토글(눈 아이콘)]
  void toggleOverlayVisibility() {
    _isOverlayVisible = !_isOverlayVisible;
    notifyListeners();
  }

  void setOverlayVisibility(bool visible) {
    if (_isOverlayVisible == visible) return;
    _isOverlayVisible = visible;
    notifyListeners();
  }

  /// 설정에서 번역 모드가 변경되었을 때 호출 (OFF 전환 시 리소스 즉시 회수)
  Future<void> onTranslationModeChanged(ComicTranslationMode mode) async {
    if (mode == ComicTranslationMode.off) {
      await _cancelAndDisposeEngines();
    }
    notifyListeners();
  }

  /// 엔진 타입(로컬 무료 <-> 클라우드 고품질)이 변경되었을 때 호출
  Future<void> onEngineTypeChanged(ComicTranslationEngineType engineType) async {
    _cloudAutoDebounceTimer?.cancel();
    _cloudAutoDebounceTimer = null;
    _visibleGeneration++;
    _clearPrefetchQueue();
    _notifiedUnsupportedOnce = false;
    _initializedEngineType = null;
    _initializedLang = null;
    if (engineType == ComicTranslationEngineType.cloudVision) {
      await _keyStorage.loadApiKey();
    }
    notifyListeners();
  }

  /// 현재 화면에 표시된 페이지(단면 1장 또는 양면 2장) 즉시 번역 요청 (수동 버튼 / Long Press)
  /// 수동 번역은 사용자가 직접 요청했으므로 디바운싱 없이 즉시 실행됩니다.
  Future<String?> translatePagesNow({
    required String bookId,
    required List<ComicPage> visiblePages,
    required ComicSourceLanguage sourceLanguage,
    required bool isRightToLeftManga,
    ComicTranslationEngineType engineType = ComicTranslationEngineType.onDevice,
  }) async {
    if (engineType == ComicTranslationEngineType.cloudVision) {
      await _keyStorage.loadApiKey();
    }
    final engine = _ensureEngineInstance(engineType);
    if (!engine.isSupported) {
      final msg = engine.unsupportedReason ?? '현재 환경에서는 선택한 번역 엔진을 사용할 수 없습니다.';
      if (!_notifiedUnsupportedOnce ||
          engineType == ComicTranslationEngineType.cloudVision) {
        _notifiedUnsupportedOnce = true;
        return msg;
      }
      return msg;
    }

    _activeBookId = bookId;
    _isOverlayVisible = true;
    notifyListeners();

    String? errorMsg;
    final futures = <Future<PageTranslationResult?>>[];
    for (final page in visiblePages) {
      futures.add(_enqueuePage(
        bookId: bookId,
        page: page,
        sourceLanguage: sourceLanguage,
        engineType: engineType,
        isRightToLeftManga: isRightToLeftManga,
        isPrefetch: false,
      ));
    }
    await Future.wait(futures);
    if (_latestNoticeMessage != null &&
        _lastNoticeAt != null &&
        DateTime.now().difference(_lastNoticeAt!) <
            const Duration(seconds: 2)) {
      errorMsg = _latestNoticeMessage;
    }
    return errorMsg;
  }

  /// 페이지 이동 또는 자동 모드 진입 시 호출:
  /// - L1/L2 캐시가 이미 존재하면 0ms 즉시 복구
  /// - [자동 번역 + 로컬 모드]: 현재 페이지 즉시 번역 + 다음 1~2페이지 백그라운드 Pre-fetch
  /// - [자동 번역 + 클라우드 모드]: 페이지 체류 시간 **1.2초 이상**일 때만 API 요청 (트래픽 폭주 방어)
  Future<String?> onPagesVisible({
    required String bookId,
    required List<ComicPage> visiblePages,
    required List<ComicPage> allPages,
    required ComicTranslationMode mode,
    required ComicSourceLanguage sourceLanguage,
    required bool isRightToLeftManga,
    ComicTranslationEngineType engineType = ComicTranslationEngineType.onDevice,
  }) async {
    _cloudAutoDebounceTimer?.cancel();
    _cloudAutoDebounceTimer = null;
    final generation = ++_visibleGeneration;

    if (mode == ComicTranslationMode.off || visiblePages.isEmpty) {
      return null;
    }

    _activeBookId = bookId;

    // L2 디스크 캐시에 이미 저장된 결과가 있다면 L1 메모리로 즉시 복구 (0ms, 재호출 방지)
    for (final page in visiblePages) {
      if (_cache.getMemory(
            bookId,
            page.index,
            sourceLanguage,
            engineType: engineType,
          ) ==
          null) {
        final diskHit = await _cache.get(
          bookId,
          page.index,
          sourceLanguage,
          engineType: engineType,
        );
        if (diskHit != null) {
          notifyListeners();
        }
      }
    }

    if (mode != ComicTranslationMode.auto) {
      return null;
    }

    if (engineType == ComicTranslationEngineType.cloudVision) {
      await _keyStorage.loadApiKey();
    }

    final engine = _ensureEngineInstance(engineType);
    if (!engine.isSupported) {
      if (!_notifiedUnsupportedOnce) {
        _notifiedUnsupportedOnce = true;
        return engine.unsupportedReason;
      }
      return null;
    }

    // 이전 페이지의 오래된 Pre-fetch 대기열은 비움
    _clearPrefetchQueue();

    if (engineType == ComicTranslationEngineType.cloudVision) {
      // 이미 화면의 모든 페이지가 캐싱되어 있으면 API 호출 예약 자체가 불필요
      final uncachedVisible = visiblePages
          .where((p) =>
              _cache.getMemory(
                bookId,
                p.index,
                sourceLanguage,
                engineType: engineType,
              ) ==
              null)
          .toList();

      if (uncachedVisible.isEmpty) {
        return null;
      }

      // [트래픽 방어] 클라우드 자동 번역은 1.2초 이상 페이지에 체류할 때만 실행
      _cloudAutoDebounceTimer = Timer(cloudAutoDebounceDuration, () {
        if (generation != _visibleGeneration || _activeBookId != bookId) {
          return;
        }
        _scheduleAutoTranslationPages(
          bookId: bookId,
          visiblePages: visiblePages,
          allPages: allPages,
          sourceLanguage: sourceLanguage,
          engineType: engineType,
          isRightToLeftManga: isRightToLeftManga,
          prefetchCount: 1,
        );
      });
      return null;
    }

    // 로컬 온디바이스 / 온라인 무료 구글 번역: 즉시 현재 페이지 + 다음 1~2페이지 Pre-fetch
    _scheduleAutoTranslationPages(
      bookId: bookId,
      visiblePages: visiblePages,
      allPages: allPages,
      sourceLanguage: sourceLanguage,
      engineType: engineType,
      isRightToLeftManga: isRightToLeftManga,
      prefetchCount: engineType == ComicTranslationEngineType.freeGoogle ? 1 : 2,
    );

    return null;
  }

  void _scheduleAutoTranslationPages({
    required String bookId,
    required List<ComicPage> visiblePages,
    required List<ComicPage> allPages,
    required ComicSourceLanguage sourceLanguage,
    required ComicTranslationEngineType engineType,
    required bool isRightToLeftManga,
    required int prefetchCount,
  }) {
    for (final page in visiblePages) {
      unawaited(_enqueuePage(
        bookId: bookId,
        page: page,
        sourceLanguage: sourceLanguage,
        engineType: engineType,
        isRightToLeftManga: isRightToLeftManga,
        isPrefetch: false,
      ));
    }

    if (prefetchCount <= 0) return;

    final maxVisibleIdx =
        visiblePages.map((p) => p.index).reduce((a, b) => a > b ? a : b);

    for (int step = 1; step <= prefetchCount; step++) {
      final nextIdx = maxVisibleIdx + step;
      if (nextIdx >= 0 && nextIdx < allPages.length) {
        unawaited(_enqueuePage(
          bookId: bookId,
          page: allPages[nextIdx],
          sourceLanguage: sourceLanguage,
          engineType: engineType,
          isRightToLeftManga: isRightToLeftManga,
          isPrefetch: true,
        ));
      }
    }
  }

  /// 뷰어 화면 종료 시 대기열을 정리하고 네이티브 OCR/번역 리소스를 해제합니다.
  Future<void> onViewerDisposed(String bookId) async {
    if (_activeBookId == bookId) {
      _activeBookId = null;
      await _cancelAndDisposeEngines();
    }
  }

  Future<void> _cancelAndDisposeEngines() async {
    _cloudAutoDebounceTimer?.cancel();
    _cloudAutoDebounceTimer = null;
    _visibleGeneration++;
    _clearPrefetchQueue();
    for (final t in _highPriorityQueue) {
      t.completer?.complete(null);
    }
    _highPriorityQueue.clear();
    _queuedOrInFlightKeys.clear();
    _translatingPages.clear();

    for (final engine in [_onDeviceEngine, _freeGoogleEngine, _cloudEngine]) {
      if (engine != null) {
        try {
          await engine.dispose();
        } catch (_) {}
      }
    }
    _initializedEngineType = null;
    _initializedLang = null;
    notifyListeners();
  }

  void _clearPrefetchQueue() {
    while (_prefetchQueue.isNotEmpty) {
      final task = _prefetchQueue.removeFirst();
      _queuedOrInFlightKeys.remove(task.taskKey);
      task.completer?.complete(null);
    }
  }

  Future<PageTranslationResult?> _enqueuePage({
    required String bookId,
    required ComicPage page,
    required ComicSourceLanguage sourceLanguage,
    required ComicTranslationEngineType engineType,
    required bool isRightToLeftManga,
    required bool isPrefetch,
  }) async {
    // 이미 L1/L2 캐시에 있으면 즉시 반환 (재번역/재호출 0회)
    final cached = await _cache.get(
      bookId,
      page.index,
      sourceLanguage,
      engineType: engineType,
    );
    if (cached != null && cached.status == PageTranslationStatus.completed) {
      notifyListeners();
      return cached;
    }

    final key = ComicTranslationCache.buildKey(
      bookId,
      page.index,
      sourceLanguage,
      engineType: engineType,
    );
    if (_queuedOrInFlightKeys.contains(key)) {
      return null;
    }

    final completer = isPrefetch ? null : Completer<PageTranslationResult?>();
    final task = _TranslationQueueTask(
      bookId: bookId,
      page: page,
      sourceLanguage: sourceLanguage,
      engineType: engineType,
      isRightToLeftManga: isRightToLeftManga,
      isPrefetch: isPrefetch,
      completer: completer,
    );

    _queuedOrInFlightKeys.add(key);
    if (isPrefetch) {
      _prefetchQueue.addLast(task);
    } else {
      _highPriorityQueue.addLast(task);
    }

    _kickWorker();
    return completer?.future;
  }

  void _kickWorker() {
    if (_isWorkerRunning) return;
    _isWorkerRunning = true;
    unawaited(_runWorkerLoop());
  }

  Future<void> _runWorkerLoop() async {
    try {
      while (_highPriorityQueue.isNotEmpty || _prefetchQueue.isNotEmpty) {
        final task = _highPriorityQueue.isNotEmpty
            ? _highPriorityQueue.removeFirst()
            : _prefetchQueue.removeFirst();

        // 사용자가 이미 다른 책으로 나갔다면 스킵
        if (_activeBookId != null && task.bookId != _activeBookId) {
          _queuedOrInFlightKeys.remove(task.taskKey);
          task.completer?.complete(null);
          continue;
        }

        PageTranslationResult? result;
        try {
          if (!task.isPrefetch) {
            _translatingPages.add(task.page.index);
            notifyListeners();
          }

          // L2 캐시 재확인
          result = await _cache.get(
            task.bookId,
            task.page.index,
            task.sourceLanguage,
            engineType: task.engineType,
          );
          if (result == null) {
            result = await _executeTranslation(task);
            if (result != null) {
              final engine = _ensureEngineInstance(task.engineType);
              final shouldCache = engine is! FreeGoogleComicTranslator ||
                  engine.shouldCacheLastResult;
              if (shouldCache) {
                await _cache.put(result);
              }
            }
          }
        } on CloudVisionException catch (e) {
          debugPrint('[ComicTranslationService] 클라우드 오류 (p.${task.page.index}): $e');
          if (e.type != CloudVisionErrorType.cancelled) {
            _emitNotice(e.message);
          }
          if (e.type == CloudVisionErrorType.quotaExceeded ||
              e.type == CloudVisionErrorType.invalidApiKey ||
              e.type == CloudVisionErrorType.missingApiKey) {
            // 할당량 초과 또는 키 오류 시 불필요한 추가 Pre-fetch 중단
            _clearPrefetchQueue();
          }
        } catch (e) {
          debugPrint('[ComicTranslationService] 작업 오류 (p.${task.page.index}): $e');
        } finally {
          _queuedOrInFlightKeys.remove(task.taskKey);
          if (_translatingPages.remove(task.page.index) || result != null) {
            notifyListeners();
          }
          task.completer?.complete(result);
        }
      }
    } finally {
      _isWorkerRunning = false;
    }
  }

  void _emitNotice(String message) {
    final now = DateTime.now();
    // 동일 오류가 연속 발생할 때 토스트 도배 방지 (3초 쿨다운)
    if (_latestNoticeMessage == message &&
        _lastNoticeAt != null &&
        now.difference(_lastNoticeAt!) < const Duration(seconds: 3)) {
      return;
    }
    _latestNoticeMessage = message;
    _lastNoticeAt = now;
    _noticeSequence++;
    notifyListeners();
  }

  Future<PageTranslationResult?> _executeTranslation(
    _TranslationQueueTask task,
  ) async {
    final engine = _ensureEngineInstance(task.engineType);
    if (!engine.isSupported) return null;

    if (_initializedEngineType != task.engineType ||
        _initializedLang != task.sourceLanguage) {
      await engine.initialize(sourceLanguage: task.sourceLanguage);
      _initializedEngineType = task.engineType;
      _initializedLang = task.sourceLanguage;
    }

    final bytes = await task.page.getBytes();
    if (bytes.isEmpty) return null;

    final dims = task.page.dimensions ?? ImageDimensionUtils.parse(bytes);
    if (dims == null || dims.width <= 0 || dims.height <= 0) {
      return null;
    }
    if (task.page.dimensions == null) {
      task.page.updateDimensions(dims);
    }

    final bubbles = await engine.translatePage(
      ComicPageTranslationRequest(
        bookId: task.bookId,
        pageIndex: task.page.index,
        imageBytes: bytes,
        imageWidth: dims.width,
        imageHeight: dims.height,
        sourceLanguage: task.sourceLanguage,
        targetLanguage: 'ko',
        isRightToLeftManga: task.isRightToLeftManga,
      ),
    );

    return PageTranslationResult(
      bookId: task.bookId,
      pageIndex: task.page.index,
      sourceLanguage: task.sourceLanguage,
      engineType: task.engineType,
      engineId: engine.engineId,
      bubbles: bubbles,
      status: PageTranslationStatus.completed,
      createdAt: DateTime.now(),
    );
  }
}
