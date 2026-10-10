import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../../models/comic_page.dart';
import '../../models/display_page_item.dart';
import '../../models/media_item.dart';
import '../../models/viewer_settings.dart';
import '../../services/cloud_service_interface.dart';
import '../../services/comic_archive_service.dart';
import '../../services/comic_cache_manager.dart';
import '../../services/reading_history_service.dart';
import '../../services/viewer_settings_service.dart';
import '../../services/zip_stream_reader.dart';
import '../widgets/comic_thumbnail_sheet.dart';
import '../widgets/viewer_settings_dialog.dart';

class ComicViewerScreen extends StatefulWidget {
  final MediaItem item;
  final CloudService service;
  final List<MediaItem>? folderSiblings;
  final int? initialPage;

  const ComicViewerScreen({
    super.key,
    required this.item,
    required this.service,
    this.folderSiblings,
    this.initialPage,
  });

  @override
  State<ComicViewerScreen> createState() => _ComicViewerScreenState();
}

class _ComicViewerScreenState extends State<ComicViewerScreen> {
  bool _isLoading = true;
  String? _errorMessage;
  double _downloadProgress = 0.0;
  String _statusText = '만화책 데이터를 준비하고 있습니다...';
  bool _isStreamed = false;
  String? _toastMessage;
  Timer? _toastTimer;

  List<ComicPage> _pages = [];
  List<DisplayPageItem> _displayItems = [];
  int _currentPageIndex = 0;
  int _currentDisplayIndex = 0;
  bool _showControls = true;

  late final PageController _pageController;
  final ItemScrollController _itemScrollController = ItemScrollController();
  final ItemPositionsListener _itemPositionsListener = ItemPositionsListener.create();

  // 이전/다음 권 이동을 위한 리스트
  late final List<MediaItem> _viewableSiblings;
  late MediaItem _currentItem;

  @override
  void initState() {
    super.initState();
    _currentItem = widget.item;
    _currentPageIndex = widget.initialPage ?? 0;
    _pageController = PageController(initialPage: _currentPageIndex);

    // 같은 폴더 내 만화책/이미지 파일들 필터링
    _viewableSiblings = (widget.folderSiblings ?? [])
        .where((it) => it.isViewable && !it.isFolder)
        .toList();

    _loadComic();
    _setupItemPositionsListener();

    // 전체화면 및 시스템 UI 모드 진입
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  void _setupItemPositionsListener() {
    _itemPositionsListener.itemPositions.addListener(() {
      final positions = _itemPositionsListener.itemPositions.value;
      if (positions.isNotEmpty) {
        // 화면에 가장 많이 보이는 첫 번째 아이템의 인덱스 추출
        final first = positions.first.index;
        if (first != _currentPageIndex && first >= 0 && first < _pages.length) {
          setState(() {
            _currentPageIndex = first;
          });
          _saveReadingProgress();
        }
      }
    });
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    _saveReadingProgress();
    _pageController.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _showModeToast(String message) {
    _toastTimer?.cancel();
    setState(() {
      _toastMessage = message;
    });
    _toastTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) {
        setState(() {
          _toastMessage = null;
        });
      }
    });
  }

  void _saveReadingProgress() {
    if (_pages.isEmpty) return;
    ReadingHistoryService.instance.updateProgress(
      id: _currentItem.id,
      accountId: widget.service.account.id,
      accountName: widget.service.account.name,
      cloudType: widget.service.account.type,
      title: _currentItem.name,
      parentFolderId: _currentItem.parentId,
      pageIndex: _currentPageIndex,
      totalPages: _pages.length,
    );
  }

  Future<void> _loadComic() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _downloadProgress = 0.0;
      _isStreamed = false;
      _statusText = '만화책 데이터를 준비하고 있습니다...';
    });

    try {
      List<ComicPage> loadedPages = [];

      if (_currentItem.isComicArchive) {
        // 1. 압축 파일 스트리밍 파싱 우선 시도 (전체 다운로드 없이 즉시 열람)
        setState(() => _statusText = '클라우드 스트리밍 파싱 중 (즉시 열람)...');
        try {
          final streamedPages = await ZipStreamReader.extractPagesStreamed(
            service: widget.service,
            item: _currentItem,
          );
          if (streamedPages.isNotEmpty) {
            loadedPages = streamedPages;
            _isStreamed = true;
          }
        } catch (streamErr) {
          debugPrint('스트리밍 파싱 실패, 전체 다운로드 폴백: $streamErr');
        }

        // 2. 스트리밍 미지원 시 전체 다운로드 캐시 폴백
        if (loadedPages.isEmpty) {
          setState(() => _statusText = '클라우드에서 만화책 다운로드 중...');
          final bytes = await ComicCacheManager.instance.loadOrDownloadComicBytes(
            widget.service,
            _currentItem,
            onProgress: (received, total) {
              if (total > 0 && mounted) {
                setState(() {
                  _downloadProgress = (received / total).clamp(0.0, 1.0);
                  final receivedMb = (received / (1024 * 1024)).toStringAsFixed(1);
                  final totalMb = (total / (1024 * 1024)).toStringAsFixed(1);
                  _statusText = '만화책 다운로드 중 ($receivedMb MB / $totalMb MB)...';
                });
              }
            },
          );

          if (!mounted) return;
          setState(() => _statusText = '만화책 페이지 압축 해제 중...');
          loadedPages = await ComicArchiveService.extractPagesFromZipBytes(bytes);
          _isStreamed = false;
        }
      } else if (_currentItem.isImage) {
        // 단일 이미지인 경우
        if (widget.service.account.id == 'local') {
          // 로컬인 경우 같은 폴더 내 이미지들을 모두 모아서 한 편의 만화로 구성
          final parentPath = _currentItem.parentId;
          if (parentPath != null && Directory(parentPath).existsSync()) {
            loadedPages = await ComicArchiveService.extractPagesFromDirectory(Directory(parentPath));
            final initialIdx = loadedPages.indexWhere((p) => p.name == _currentItem.name);
            if (initialIdx >= 0) {
              _currentPageIndex = initialIdx;
            }
          } else {
            loadedPages = [
              ComicPage(
                index: 0,
                name: _currentItem.name,
                filePath: _currentItem.id,
                byteGetter: () => File(_currentItem.id).readAsBytes(),
              ),
            ];
          }
        } else {
          // 클라우드 단일 이미지인 경우
          final bytes = await widget.service.downloadBytes(_currentItem);
          loadedPages = [
            ComicPage(
              index: 0,
              name: _currentItem.name,
              initialBytes: bytes,
            ),
          ];
        }
      }

      if (loadedPages.isEmpty) {
        throw Exception('만화책 내에 열람 가능한 이미지 페이지가 없습니다.');
      }

      if (mounted) {
        // 저장된 이전 읽기 기록이 있다면 반영
        final savedHistory = ReadingHistoryService.instance.getHistory(_currentItem.id);
        int targetPage = widget.initialPage ?? savedHistory?.lastPage ?? 0;
        if (targetPage >= loadedPages.length) {
          targetPage = loadedPages.length - 1;
        }

        setState(() {
          _pages = loadedPages;
          _currentPageIndex = targetPage;
          _isLoading = false;
        });

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_pageController.hasClients) {
            final targetDisplay = DisplayPageBuilder.findDisplayIndex(_displayItems, _currentPageIndex);
            _pageController.jumpToPage(targetDisplay);
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = e.toString();
        });
      }
    }
  }

  void _onDisplayPageChanged(int displayIndex) {
    if (displayIndex < 0 || displayIndex >= _displayItems.length) return;
    setState(() {
      _currentDisplayIndex = displayIndex;
      _currentPageIndex = _displayItems[displayIndex].primaryOriginalIndex;
    });
    _saveReadingProgress();
  }

  void _jumpToPage(int originalIndex) {
    if (originalIndex < 0 || originalIndex >= _pages.length) return;
    setState(() {
      _currentPageIndex = originalIndex;
    });

    final settings = ViewerSettingsService.instance.settings;
    if (settings.viewerMode == ViewerMode.singlePage) {
      final targetDisplay = DisplayPageBuilder.findDisplayIndex(_displayItems, originalIndex);
      _currentDisplayIndex = targetDisplay;
      if (_pageController.hasClients) {
        _pageController.jumpToPage(targetDisplay);
      }
    } else {
      if (_itemScrollController.isAttached) {
        _itemScrollController.jumpTo(index: originalIndex);
      }
    }
    _saveReadingProgress();
  }

  void _toggleControls() {
    setState(() {
      _showControls = !_showControls;
    });
  }

  // 이전 권 / 다음 권 이동
  void _switchVolume(int delta) {
    if (_viewableSiblings.isEmpty) return;
    final currentIdx = _viewableSiblings.indexWhere((it) => it.id == _currentItem.id);
    if (currentIdx == -1) return;

    final targetIdx = currentIdx + delta;
    if (targetIdx >= 0 && targetIdx < _viewableSiblings.length) {
      _saveReadingProgress();
      setState(() {
        _currentItem = _viewableSiblings[targetIdx];
        _currentPageIndex = 0;
      });
      _loadComic();
    }
  }

  void _cycleDisplayMode(ViewerSettingsService settingsService) {
    final current = settingsService.settings.displayMode;
    final next = switch (current) {
      PageDisplayMode.auto => PageDisplayMode.split,
      PageDisplayMode.split => PageDisplayMode.spread,
      PageDisplayMode.spread => PageDisplayMode.single,
      PageDisplayMode.single => PageDisplayMode.auto,
    };
    settingsService.setDisplayMode(next);
    _showModeToast('보기 모드: ${next.label}');
  }

  @override
  Widget build(BuildContext context) {
    final settingsService = ViewerSettingsService.instance;
    final orientation = MediaQuery.of(context).orientation;

    return AnimatedBuilder(
      animation: settingsService,
      builder: (context, _) {
        final settings = settingsService.settings;
        final bgColor = settings.theme.color;

        // 현재 설정 및 화면 방향에 맞춰 표시 아이템 목록 동기화
        if (_pages.isNotEmpty) {
          final newItems = DisplayPageBuilder.buildItems(
            pages: _pages,
            mode: settings.displayMode,
            direction: settings.readingDirection,
            orientation: orientation,
          );
          if (_displayItems.length != newItems.length) {
            _displayItems = newItems;
            final targetDisplay = DisplayPageBuilder.findDisplayIndex(_displayItems, _currentPageIndex);
            _currentDisplayIndex = targetDisplay;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_pageController.hasClients && _pageController.page?.round() != _currentDisplayIndex) {
                _pageController.jumpToPage(_currentDisplayIndex);
              }
            });
          } else {
            _displayItems = newItems;
          }
        }

        return Scaffold(
          backgroundColor: bgColor,
          body: Stack(
            children: [
              // 1. 만화책 메인 뷰어 영역
              Positioned.fill(
                child: _buildViewerContent(settings, orientation),
              ),

              // 2. 상단 앱바 오버레이
              if (_showControls)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: _buildTopBar(settingsService),
                ),

              // 3. 중앙 모드 변경 토스트 오버레이
              if (_toastMessage != null)
                Positioned(
                  top: MediaQuery.of(context).padding.top + 64,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                      decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.6), width: 1.5),
                        boxShadow: const [
                          BoxShadow(color: Colors.black45, blurRadius: 10, offset: Offset(0, 3)),
                        ],
                      ),
                      child: Text(
                        _toastMessage!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),

              // 4. 하단 컨트롤 툴바 오버레이
              if (_showControls && !_isLoading && _pages.isNotEmpty)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: _buildBottomBar(settingsService),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildViewerContent(ViewerSettings settings, Orientation orientation) {
    if (_isLoading) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Colors.blueAccent),
              const SizedBox(height: 24),
              Text(
                _statusText,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                textAlign: TextAlign.center,
              ),
              if (_downloadProgress > 0) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(
                  value: _downloadProgress,
                  backgroundColor: Colors.white12,
                  valueColor: const AlwaysStoppedAnimation<Color>(Colors.blueAccent),
                ),
                const SizedBox(height: 8),
                Text(
                  '${(_downloadProgress * 100).toInt()}%',
                  style: const TextStyle(color: Colors.blueAccent, fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ],
            ],
          ),
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.redAccent, size: 56),
              const SizedBox(height: 16),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: _loadComic,
                icon: const Icon(Icons.refresh),
                label: const Text('다시 시도'),
              ),
            ],
          ),
        ),
      );
    }

    if (_pages.isEmpty) {
      return const Center(
        child: Text('표시할 이미지가 없습니다.', style: TextStyle(color: Colors.white70)),
      );
    }

    // 웹툰 모드 (세로 스크롤)
    if (settings.viewerMode == ViewerMode.webtoon) {
      return GestureDetector(
        onTap: _toggleControls,
        child: ScrollablePositionedList.builder(
          itemScrollController: _itemScrollController,
          itemPositionsListener: _itemPositionsListener,
          initialScrollIndex: _currentPageIndex,
          itemCount: _pages.length,
          itemBuilder: (context, index) {
            return _buildSinglePageImage(_pages[index], settings, index);
          },
        ),
      );
    }

    // 페이지 모드 (가로 넘김, 분할/합침 아이템 지원)
    final isRtoL = settings.readingDirection == ReadingDirection.rightToLeft;
    final itemsCount = _displayItems.isNotEmpty ? _displayItems.length : _pages.length;

    return GestureDetector(
      onTap: _toggleControls,
      child: PageView.builder(
        controller: _pageController,
        reverse: isRtoL,
        itemCount: itemsCount,
        onPageChanged: _onDisplayPageChanged,
        itemBuilder: (context, index) {
          if (_displayItems.isEmpty) {
            return Center(
              child: InteractiveViewer(
                minScale: 1.0,
                maxScale: 4.0,
                child: _buildSinglePageImage(_pages[index], settings, index),
              ),
            );
          }

          final item = _displayItems[index];
          return Center(
            child: InteractiveViewer(
              minScale: 1.0,
              maxScale: 4.0,
              child: _buildDisplayItemWidget(item, settings),
            ),
          );
        },
      ),
    );
  }

  Widget _buildDisplayItemWidget(DisplayPageItem item, ViewerSettings settings) {
    switch (item.type) {
      case DisplayItemType.single:
        return _buildSinglePageImage(item.primaryPage, settings, item.primaryOriginalIndex);
      case DisplayItemType.splitLeft:
        return _buildSplitPageImage(item.primaryPage, isLeft: true, settings: settings, index: item.primaryOriginalIndex);
      case DisplayItemType.splitRight:
        return _buildSplitPageImage(item.primaryPage, isLeft: false, settings: settings, index: item.primaryOriginalIndex);
      case DisplayItemType.spread:
        return _buildSpreadPageImage(item.primaryPage, item.secondaryPage, settings: settings);
    }
  }

  /// 단일 페이지 렌더러
  Widget _buildSinglePageImage(ComicPage page, ViewerSettings settings, int index) {
    BoxFit fit;
    switch (settings.fitMode) {
      case FitMode.fitWidth:
        fit = BoxFit.fitWidth;
        break;
      case FitMode.fitHeight:
        fit = BoxFit.fitHeight;
        break;
      case FitMode.contain:
        fit = BoxFit.contain;
        break;
    }

    return FutureBuilder<Uint8List>(
      future: page.getBytes(),
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          return Image.memory(
            snapshot.data!,
            fit: fit,
            filterQuality: FilterQuality.medium,
            errorBuilder: (context, error, stackTrace) => Container(
              height: 300,
              color: Colors.black12,
              child: Center(
                child: Text('${index + 1}p 이미지 로드 실패', style: const TextStyle(color: Colors.white54)),
              ),
            ),
          );
        }
        return _buildLoadingPlaceholder();
      },
    );
  }

  /// 좌우 분할 페이지 렌더러 (ClipRect + Align 50% widthFactor 무손실 고속 분할)
  Widget _buildSplitPageImage(
    ComicPage page, {
    required bool isLeft,
    required ViewerSettings settings,
    required int index,
  }) {
    return FutureBuilder<Uint8List>(
      future: page.getBytes(),
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          return LayoutBuilder(
            builder: (context, constraints) {
              return Center(
                child: ClipRect(
                  child: Align(
                    alignment: isLeft ? Alignment.centerLeft : Alignment.centerRight,
                    widthFactor: 0.5,
                    child: Image.memory(
                      snapshot.data!,
                      fit: BoxFit.fitHeight,
                      height: constraints.maxHeight,
                      filterQuality: FilterQuality.medium,
                      errorBuilder: (context, error, stackTrace) => Container(
                        height: 300,
                        color: Colors.black12,
                        child: Center(
                          child: Text('${index + 1}p 이미지 로드 실패', style: const TextStyle(color: Colors.white54)),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        }
        return _buildLoadingPlaceholder();
      },
    );
  }

  /// 두 장 나란히 합쳐보기 렌더러 (Landscape 모드 듀얼 페이지 펼침)
  Widget _buildSpreadPageImage(
    ComicPage leftPage,
    ComicPage? rightPage, {
    required ViewerSettings settings,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Center(
            child: _buildSinglePageImage(leftPage, settings, leftPage.index),
          ),
        ),
        if (rightPage != null) ...[
          Container(width: 1, color: Colors.black38),
          Expanded(
            child: Center(
              child: _buildSinglePageImage(rightPage, settings, rightPage.index),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildLoadingPlaceholder() {
    return Container(
      height: 400,
      color: Colors.black12,
      child: const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.blueAccent),
        ),
      ),
    );
  }

  Widget _buildTopBar(ViewerSettingsService settingsService) {
    final pageLabel = _displayItems.isNotEmpty && _currentDisplayIndex < _displayItems.length
        ? _displayItems[_currentDisplayIndex].label
        : '${_currentPageIndex + 1}p';

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + 8,
        left: 8,
        right: 8,
        bottom: 16,
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.pop(context),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        _currentItem.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    if (_isStreamed) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.blueAccent.withValues(alpha: 0.8),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.bolt, color: Colors.yellowAccent, size: 12),
                            SizedBox(width: 2),
                            Text('스트리밍', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
                if (_pages.isNotEmpty)
                  Text(
                    '$pageLabel / ${_pages.length} 페이지  •  ${settingsService.settings.displayMode.label}',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
          // 보기 모드 (자동 / 분할 / 합침 / 1페이지) 토글 버튼
          IconButton(
            icon: Icon(
              settingsService.settings.displayMode.icon,
              color: Colors.blueAccent,
            ),
            tooltip: '화면 보기 모드: ${settingsService.settings.displayMode.label}',
            onPressed: () => _cycleDisplayMode(settingsService),
          ),
          // 웹툰 <-> 페이지 모드 빠른 토글 버튼
          IconButton(
            icon: Icon(
              settingsService.settings.viewerMode == ViewerMode.webtoon
                  ? Icons.view_day
                  : Icons.auto_stories,
              color: Colors.white,
            ),
            tooltip: settingsService.settings.viewerMode == ViewerMode.webtoon
                ? '페이지 모드로 전환'
                : '웹툰 모드로 전환',
            onPressed: () {
              final newMode = settingsService.settings.viewerMode == ViewerMode.webtoon
                  ? ViewerMode.singlePage
                  : ViewerMode.webtoon;
              settingsService.setViewerMode(newMode);
            },
          ),
          // 뷰어 설정 버튼
          IconButton(
            icon: const Icon(Icons.tune, color: Colors.white),
            tooltip: '뷰어 설정',
            onPressed: () => ViewerSettingsDialog.show(context, settingsService),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar(ViewerSettingsService settingsService) {
    final currentSettings = settingsService.settings;
    final hasPrevVol = _viewableSiblings.isNotEmpty &&
        _viewableSiblings.indexWhere((it) => it.id == _currentItem.id) > 0;
    final hasNextVol = _viewableSiblings.isNotEmpty &&
        _viewableSiblings.indexWhere((it) => it.id == _currentItem.id) < _viewableSiblings.length - 1;

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).padding.bottom + 8,
        left: 16,
        right: 16,
        top: 8,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 1. 화면 분할 / 합침 모드 퀵 토글 바 (화면 터치 시 표시)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white12),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: PageDisplayMode.values.map((mode) {
                  final isSelected = currentSettings.displayMode == mode;
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () {
                        settingsService.setDisplayMode(mode);
                        _showModeToast('보기 모드: ${mode.label}');
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: isSelected ? Colors.blueAccent : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              mode.icon,
                              size: 15,
                              color: isSelected ? Colors.white : Colors.white70,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              mode.label.split(' ').first, // 짧은 라벨
                              style: TextStyle(
                                color: isSelected ? Colors.white : Colors.white70,
                                fontSize: 12,
                                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),

          // 2. 페이지 탐색 슬라이더
          Row(
            children: [
              Text(
                '${_currentPageIndex + 1}',
                style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
              ),
              Expanded(
                child: Slider(
                  value: _currentPageIndex.toDouble().clamp(0.0, (_pages.length - 1).toDouble().clamp(0.0, double.infinity)),
                  min: 0,
                  max: (_pages.length - 1).toDouble().clamp(0, double.infinity),
                  divisions: _pages.length > 1 ? _pages.length - 1 : 1,
                  activeColor: Colors.blueAccent,
                  inactiveColor: Colors.white24,
                  onChanged: (val) {
                    _jumpToPage(val.round());
                  },
                ),
              ),
              Text(
                '${_pages.length}',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ],
          ),

          // 3. 하단 툴바 버튼들
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              // 이전 권
              IconButton(
                icon: const Icon(Icons.skip_previous, color: Colors.white),
                tooltip: '이전 권/파일',
                onPressed: hasPrevVol ? () => _switchVolume(-1) : null,
              ),
              // 이전 페이지
              IconButton(
                icon: const Icon(Icons.navigate_before, color: Colors.white),
                tooltip: '이전 페이지',
                onPressed: _currentPageIndex > 0 ? () => _jumpToPage(_currentPageIndex - 1) : null,
              ),
              // 목차 및 전체 썸네일 그리드
              IconButton(
                icon: const Icon(Icons.grid_view, color: Colors.blueAccent),
                tooltip: '전체 페이지 썸네일 목차',
                onPressed: () {
                  ComicThumbnailSheet.show(
                    context,
                    pages: _pages,
                    currentPageIndex: _currentPageIndex,
                    onPageSelected: (selectedIdx) {
                      _jumpToPage(selectedIdx);
                    },
                  );
                },
              ),
              // 다음 페이지
              IconButton(
                icon: const Icon(Icons.navigate_next, color: Colors.white),
                tooltip: '다음 페이지',
                onPressed: _currentPageIndex < _pages.length - 1
                    ? () => _jumpToPage(_currentPageIndex + 1)
                    : null,
              ),
              // 다음 권
              IconButton(
                icon: const Icon(Icons.skip_next, color: Colors.white),
                tooltip: '다음 권/파일',
                onPressed: hasNextVol ? () => _switchVolume(1) : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

