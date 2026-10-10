import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../../models/comic_page.dart';
import '../../models/media_item.dart';
import '../../models/viewer_settings.dart';
import '../../services/cloud_service_interface.dart';
import '../../services/comic_archive_service.dart';
import '../../services/comic_cache_manager.dart';
import '../../services/reading_history_service.dart';
import '../../services/viewer_settings_service.dart';
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

  List<ComicPage> _pages = [];
  int _currentPageIndex = 0;
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
    _saveReadingProgress();
    _pageController.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
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
      _statusText = '만화책 데이터를 준비하고 있습니다...';
    });

    try {
      List<ComicPage> loadedPages = [];

      if (_currentItem.isComicArchive) {
        // 압축 파일(.zip, .cbz 등) 처리
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
            _pageController.jumpToPage(_currentPageIndex);
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

  void _onPageChanged(int index) {
    setState(() {
      _currentPageIndex = index;
    });
    _saveReadingProgress();
  }

  void _jumpToPage(int index) {
    if (index < 0 || index >= _pages.length) return;
    setState(() {
      _currentPageIndex = index;
    });

    final settings = ViewerSettingsService.instance.settings;
    if (settings.viewerMode == ViewerMode.singlePage) {
      if (_pageController.hasClients) {
        _pageController.jumpToPage(index);
      }
    } else {
      if (_itemScrollController.isAttached) {
        _itemScrollController.jumpTo(index: index);
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

  @override
  Widget build(BuildContext context) {
    final settingsService = ViewerSettingsService.instance;

    return AnimatedBuilder(
      animation: settingsService,
      builder: (context, _) {
        final settings = settingsService.settings;
        final bgColor = settings.theme.color;

        return Scaffold(
          backgroundColor: bgColor,
          body: Stack(
            children: [
              // 1. 만화책 메인 뷰어 영역
              Positioned.fill(
                child: _buildViewerContent(settings),
              ),

              // 2. 상단 앱바 오버레이
              if (_showControls)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: _buildTopBar(settingsService),
                ),

              // 3. 하단 컨트롤 툴바 오버레이
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

  Widget _buildViewerContent(ViewerSettings settings) {
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
            return _buildPageImage(_pages[index], settings, index);
          },
        ),
      );
    }

    // 페이지 모드 (가로 넘김)
    final isRtoL = settings.readingDirection == ReadingDirection.rightToLeft;

    return GestureDetector(
      onTap: _toggleControls,
      child: PageView.builder(
        controller: _pageController,
        reverse: isRtoL,
        itemCount: _pages.length,
        onPageChanged: _onPageChanged,
        itemBuilder: (context, index) {
          return Center(
            child: InteractiveViewer(
              minScale: 1.0,
              maxScale: 4.0,
              child: _buildPageImage(_pages[index], settings, index),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPageImage(ComicPage page, ViewerSettings settings, int index) {
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
      },
    );
  }

  Widget _buildTopBar(ViewerSettingsService settingsService) {
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
                Text(
                  _currentItem.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (_pages.isNotEmpty)
                  Text(
                    '${_currentPageIndex + 1} / ${_pages.length} 페이지',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
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
        top: 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 1. 페이지 탐색 슬라이더
          Row(
            children: [
              Text(
                '${_currentPageIndex + 1}',
                style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
              ),
              Expanded(
                child: Slider(
                  value: _currentPageIndex.toDouble(),
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
          // 2. 하단 툴바 버튼들
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
