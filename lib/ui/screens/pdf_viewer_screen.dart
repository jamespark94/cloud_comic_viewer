import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:provider/provider.dart';
import '../../models/ebook_content.dart';
import '../../models/media_item.dart';
import '../../models/viewer_settings.dart';
import '../../services/account_manager.dart';
import '../../services/cloud_history_sync_service.dart';
import '../../services/cloud_service_interface.dart';
import '../../services/comic_cache_manager.dart';
import '../../services/reading_history_service.dart';
import '../../services/viewer_settings_service.dart';
import '../../utils/natural_sort_utils.dart';
import '../widgets/ebook_settings_sheet.dart';

class PdfViewerScreen extends StatefulWidget {
  final MediaItem item;
  final CloudService service;
  final List<MediaItem>? folderSiblings;
  final String? parentFolderId;
  final int? initialPage; // 0-based page index

  const PdfViewerScreen({
    super.key,
    required this.item,
    required this.service,
    this.folderSiblings,
    this.parentFolderId,
    this.initialPage,
  });

  @override
  State<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends State<PdfViewerScreen> {
  bool _isLoading = true;
  String? _errorMessage;
  double _downloadProgress = 0.0;
  String _statusText = 'PDF 문서를 준비하고 있습니다...';

  File? _localPdfFile;
  late MediaItem _currentItem;
  List<MediaItem> _pdfSiblings = [];
  List<EbookBookmark> _bookmarks = [];
  List<PdfOutlineNode> _outline = [];

  final PdfViewerController _pdfController = PdfViewerController();
  final FocusNode _focusNode = FocusNode();

  int _currentPageNumber = 1; // 1-based
  int _totalPageCount = 1;
  bool _showControls = true;

  String? _toastMessage;
  Timer? _toastTimer;

  // PDF 야간 다크 반전 컬러 매트릭스
  static const List<double> _invertColorMatrix = <double>[
    -1,  0,  0, 0, 255,
     0, -1,  0, 0, 255,
     0,  0, -1, 0, 255,
     0,  0,  0, 1,   0,
  ];

  @override
  void initState() {
    super.initState();
    _currentItem = widget.item;
    _initSiblings();
    _loadPdf(initialPageZeroBased: widget.initialPage);
  }

  void _initSiblings() {
    final siblings = widget.folderSiblings ?? [];
    _pdfSiblings = siblings
        .where((it) => !it.isFolder && it.isPdf)
        .toList()
      ..sort((a, b) => NaturalSortUtils.compare(a.name, b.name));
  }

  int get _currentSiblingIndex =>
      _pdfSiblings.indexWhere((it) => it.id == _currentItem.id);

  bool get _hasPrevBook => _currentSiblingIndex > 0;
  bool get _hasNextBook =>
      _currentSiblingIndex != -1 && _currentSiblingIndex < _pdfSiblings.length - 1;

  @override
  void dispose() {
    _toastTimer?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  void _showToast(String msg) {
    _toastTimer?.cancel();
    if (!mounted) return;
    setState(() => _toastMessage = msg);
    _toastTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _toastMessage = null);
    });
  }

  Future<void> _loadPdf({int? initialPageZeroBased}) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _downloadProgress = 0.0;
      _statusText = '\'${_currentItem.name}\' 다운로드 중...';
    });

    try {
      final existingHistory = ReadingHistoryService.instance.getHistory(_currentItem.id);
      _bookmarks = List<EbookBookmark>.from(existingHistory?.bookmarks ?? const []);

      final file = await ComicCacheManager.instance.loadOrDownloadFile(
        widget.service,
        _currentItem,
        onProgress: (received, total) {
          if (!mounted) return;
          if (total > 0) {
            setState(() {
              _downloadProgress = (received / total).clamp(0.0, 1.0);
              _statusText =
                  'PDF 로드 중... ${(_downloadProgress * 100).toStringAsFixed(0)}%';
            });
          }
        },
      );

      final startPageZero = initialPageZeroBased ?? existingHistory?.lastPage ?? 0;
      _currentPageNumber = math.max(1, startPageZero + 1);

      if (!mounted) return;
      setState(() {
        _localPdfFile = file;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'PDF 파일을 열 수 없습니다: $e';
      });
    }
  }

  void _goToPage(int pageNumber) {
    if (!_pdfController.isReady) return;
    final int clamped = pageNumber.clamp(1, math.max(1, _totalPageCount)).toInt();
    _pdfController.goToPage(pageNumber: clamped);
  }

  void _nextPage() {
    if (!_pdfController.isReady) return;
    if (_currentPageNumber < _totalPageCount) {
      _goToPage(_currentPageNumber + 1);
    } else if (_hasNextBook) {
      _switchBook(_pdfSiblings[_currentSiblingIndex + 1]);
    } else {
      _showToast('마지막 페이지입니다.');
    }
  }

  void _prevPage() {
    if (!_pdfController.isReady) return;
    if (_currentPageNumber > 1) {
      _goToPage(_currentPageNumber - 1);
    } else if (_hasPrevBook) {
      _switchBook(_pdfSiblings[_currentSiblingIndex - 1]);
    } else {
      _showToast('첫 페이지입니다.');
    }
  }

  void _switchBook(MediaItem nextItem) {
    _currentItem = nextItem;
    _localPdfFile = null;
    _outline = [];
    _showToast('\'${nextItem.name}\' 열기');
    _loadPdf(initialPageZeroBased: 0);
  }

  bool get _isCurrentPageBookmarked =>
      _bookmarks.any((b) => b.charOffset == _currentPageNumber);

  void _togglePageBookmark() {
    final existingIdx = _bookmarks.indexWhere((b) => b.charOffset == _currentPageNumber);
    if (existingIdx != -1) {
      setState(() {
        _bookmarks.removeAt(existingIdx);
      });
      _saveHistory();
      _showToast('$_currentPageNumber페이지 책갈피가 해제되었습니다.');
      return;
    }

    final bm = EbookBookmark(
      id: 'pdf_bm_${DateTime.now().millisecondsSinceEpoch}',
      chapterIndex: _currentPageNumber - 1,
      chapterTitle: '$_currentPageNumber 페이지',
      charOffset: _currentPageNumber,
      snippet: '${_currentItem.name} - $_currentPageNumber / $_totalPageCount 페이지',
      createdAt: DateTime.now(),
    );

    setState(() {
      _bookmarks.add(bm);
      _bookmarks.sort((a, b) => a.charOffset.compareTo(b.charOffset));
    });
    _saveHistory();
    _showToast('$_currentPageNumber페이지에 책갈피를 꽂았습니다.');
  }

  void _saveHistory() {
    ReadingHistoryService.instance.updateProgress(
      id: _currentItem.id,
      accountId: widget.service.account.id,
      accountName: widget.service.account.name,
      cloudType: widget.service.account.type,
      title: _currentItem.name,
      parentFolderId: widget.parentFolderId ?? _currentItem.parentId,
      pageIndex: math.max(0, _currentPageNumber - 1),
      totalPages: math.max(1, _totalPageCount),
      bookType: 'pdf',
      bookmarks: _bookmarks,
    );

    if (mounted) {
      final accountMgr = context.read<AccountManager>();
      CloudHistorySyncService.instance.scheduleAutoPush(accountMgr);
    }
  }

  void _openOutlineAndBookmarksSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1F2B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return DefaultTabController(
          length: 2,
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.72,
            child: Column(
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                TabBar(
                  indicatorColor: Colors.blueAccent,
                  labelColor: Colors.blueAccent,
                  unselectedLabelColor: Colors.white60,
                  tabs: [
                    Tab(
                      icon: const Icon(Icons.format_list_bulleted, size: 18),
                      text: '내장 목차 (${_outline.length})',
                    ),
                    Tab(
                      icon: const Icon(Icons.bookmarks_outlined, size: 18),
                      text: '책갈피 (${_bookmarks.length})',
                    ),
                  ],
                ),
                const Divider(height: 1, color: Colors.white12),
                Expanded(
                  child: TabBarView(
                    children: [
                      // 1. 내장 Outline 목차
                      _outline.isEmpty
                          ? const Center(
                              child: Text(
                                '이 PDF 문서에는 내장된 목차(Outline)가 없습니다.',
                                style: TextStyle(color: Colors.white54, fontSize: 13),
                              ),
                            )
                          : ListView.builder(
                              itemCount: _outline.length,
                              itemBuilder: (context, idx) {
                                final node = _outline[idx];
                                final pageNum = node.dest?.pageNumber;
                                return ListTile(
                                  dense: true,
                                  leading: const Icon(Icons.bookmark_border, color: Colors.blueAccent, size: 18),
                                  title: Text(
                                    node.title,
                                    style: const TextStyle(color: Colors.white, fontSize: 13.5),
                                  ),
                                  trailing: pageNum != null
                                      ? Text(
                                          '${pageNum}p',
                                          style: const TextStyle(color: Colors.blueAccent, fontSize: 12),
                                        )
                                      : null,
                                  onTap: () {
                                    Navigator.pop(ctx);
                                    if (node.dest != null) {
                                      _pdfController.goToDest(node.dest);
                                    }
                                  },
                                );
                              },
                            ),
                      // 2. 책갈피 목록
                      _bookmarks.isEmpty
                          ? const Center(
                              child: Text(
                                '등록된 책갈피가 없습니다.',
                                style: TextStyle(color: Colors.white54, fontSize: 13),
                              ),
                            )
                          : ListView.separated(
                              itemCount: _bookmarks.length,
                              separatorBuilder: (_, _) => const Divider(height: 1, color: Colors.white10),
                              itemBuilder: (context, idx) {
                                final bm = _bookmarks[idx];
                                return ListTile(
                                  leading: const Icon(Icons.bookmark, color: Colors.amber, size: 20),
                                  title: Text(
                                    bm.chapterTitle,
                                    style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 13),
                                  ),
                                  subtitle: Text(
                                    bm.snippet,
                                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                                  ),
                                  trailing: IconButton(
                                    icon: const Icon(Icons.delete_outline, color: Colors.white38, size: 18),
                                    onPressed: () {
                                      setState(() {
                                        _bookmarks.removeWhere((e) => e.id == bm.id);
                                      });
                                      _saveHistory();
                                      Navigator.pop(ctx);
                                      _openOutlineAndBookmarksSheet();
                                    },
                                  ),
                                  onTap: () {
                                    Navigator.pop(ctx);
                                    _goToPage(bm.charOffset);
                                  },
                                );
                              },
                            ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _openSettingsSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const EbookSettingsSheet(isPdf: true),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ViewerSettingsService>(
      builder: (context, settingsSvc, _) {
        final s = settingsSvc.settings;

        return KeyboardListener(
          focusNode: _focusNode,
          autofocus: true,
          onKeyEvent: (event) {
            if (event is! KeyDownEvent) return;
            final key = event.logicalKey;
            if (key == LogicalKeyboardKey.arrowRight ||
                key == LogicalKeyboardKey.pageDown ||
                key == LogicalKeyboardKey.space ||
                (s.useVolumeKeysForPageTurn && key == LogicalKeyboardKey.audioVolumeDown)) {
              _nextPage();
            } else if (key == LogicalKeyboardKey.arrowLeft ||
                key == LogicalKeyboardKey.pageUp ||
                (s.useVolumeKeysForPageTurn && key == LogicalKeyboardKey.audioVolumeUp)) {
              _prevPage();
            } else if (key == LogicalKeyboardKey.escape) {
              Navigator.of(context).maybePop();
            }
          },
          child: Scaffold(
            backgroundColor: s.theme.color,
            body: SafeArea(
              child: Stack(
                children: [
                  _buildPdfBody(context, s),
                  if (_showControls && !_isLoading && _localPdfFile != null) ...[
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: _buildTopBar(context, s),
                    ),
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: _buildBottomBar(context),
                    ),
                  ],
                  if (_toastMessage != null)
                    Positioned(
                      bottom: _showControls ? 130 : 36,
                      left: 24,
                      right: 24,
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                          decoration: BoxDecoration(
                            color: Colors.black87,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.white24),
                          ),
                          child: Text(
                            _toastMessage!,
                            style: const TextStyle(color: Colors.white, fontSize: 12.5),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPdfBody(BuildContext context, ViewerSettings s) {
    if (_isLoading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Colors.blueAccent),
            const SizedBox(height: 16),
            Text(_statusText, style: TextStyle(color: s.theme.textColor, fontSize: 14)),
            if (_downloadProgress > 0 && _downloadProgress < 1.0) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: 220,
                child: LinearProgressIndicator(
                  value: _downloadProgress,
                  backgroundColor: Colors.white12,
                  color: Colors.blueAccent,
                ),
              ),
            ],
          ],
        ),
      );
    }

    if (_errorMessage != null || _localPdfFile == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.redAccent, size: 52),
              const SizedBox(height: 12),
              Text(
                _errorMessage ?? 'PDF 로드 실패',
                textAlign: TextAlign.center,
                style: TextStyle(color: s.theme.textColor),
              ),
              const SizedBox(height: 18),
              ElevatedButton.icon(
                onPressed: () => _loadPdf(initialPageZeroBased: _currentPageNumber - 1),
                icon: const Icon(Icons.refresh),
                label: const Text('다시 시도'),
              ),
            ],
          ),
        ),
      );
    }

    Widget viewer = GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapUp: (details) {
        final w = MediaQuery.of(context).size.width;
        final dx = details.localPosition.dx;
        if (dx < w * 0.22) {
          _prevPage();
        } else if (dx > w * 0.78) {
          _nextPage();
        } else {
          setState(() => _showControls = !_showControls);
        }
      },
      child: PdfViewer.file(
        _localPdfFile!.path,
        controller: _pdfController,
        initialPageNumber: _currentPageNumber,
        params: PdfViewerParams(
          backgroundColor: s.theme.color,
          onViewerReady: (document, controller) async {
            if (!mounted) return;
            setState(() {
              _totalPageCount = document.pages.length;
            });
            _saveHistory();
            try {
              final loadedOutline = await document.loadOutline();
              if (mounted) {
                setState(() => _outline = loadedOutline);
              }
            } catch (_) {}
          },
          onPageChanged: (pageNumber) {
            if (pageNumber == null || !mounted) return;
            setState(() {
              _currentPageNumber = pageNumber;
            });
            _saveHistory();
          },
        ),
      ),
    );

    if (s.pdfDarkInvert) {
      viewer = ColorFiltered(
        colorFilter: const ColorFilter.matrix(_invertColorMatrix),
        child: viewer,
      );
    }

    return viewer;
  }

  Widget _buildTopBar(BuildContext context, ViewerSettings s) {
    final isBookmarked = _isCurrentPageBookmarked;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withAlpha(220),
            Colors.black.withAlpha(150),
            Colors.transparent,
          ],
        ),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.of(context).pop(),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _currentItem.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                ),
                Text(
                  'PDF • $_currentPageNumber / $_totalPageCount 페이지',
                  style: const TextStyle(color: Colors.redAccent, fontSize: 11),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(
              s.pdfDarkInvert ? Icons.dark_mode : Icons.light_mode_outlined,
              color: s.pdfDarkInvert ? Colors.amber : Colors.white,
            ),
            tooltip: 'PDF 야간 색상 반전 토글',
            onPressed: () => ViewerSettingsService.instance.togglePdfDarkInvert(),
          ),
          IconButton(
            icon: Icon(
              isBookmarked ? Icons.bookmark : Icons.bookmark_border,
              color: isBookmarked ? Colors.amber : Colors.white,
            ),
            tooltip: '현재 페이지 책갈피',
            onPressed: _togglePageBookmark,
          ),
          IconButton(
            icon: const Icon(Icons.tune, color: Colors.white),
            tooltip: 'PDF 뷰어 설정',
            onPressed: _openSettingsSheet,
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar(BuildContext context) {
    final maxSlider = math.max(1.0, _totalPageCount.toDouble());
    final currentVal = _currentPageNumber.toDouble().clamp(1.0, maxSlider);

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: const Color(0xFF141822).withAlpha(242),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        border: const Border(top: BorderSide(color: Colors.white12)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.chevron_left, color: Colors.white70),
                onPressed: _currentPageNumber > 1 ? _prevPage : null,
              ),
              Expanded(
                child: Slider(
                  value: currentVal,
                  min: 1.0,
                  max: maxSlider,
                  divisions: _totalPageCount > 1 ? _totalPageCount - 1 : 1,
                  activeColor: Colors.redAccent,
                  inactiveColor: Colors.white24,
                  label: '$_currentPageNumber p',
                  onChanged: (v) => _goToPage(v.round()),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.chevron_right, color: Colors.white70),
                onPressed: _currentPageNumber < _totalPageCount ? _nextPage : null,
              ),
              SizedBox(
                width: 64,
                child: Text(
                  '$_currentPageNumber/$_totalPageCount',
                  textAlign: TextAlign.right,
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              TextButton.icon(
                onPressed: _hasPrevBook
                    ? () => _switchBook(_pdfSiblings[_currentSiblingIndex - 1])
                    : null,
                icon: const Icon(Icons.fast_rewind, size: 17),
                label: const Text('이전 권', style: TextStyle(fontSize: 12)),
              ),
              TextButton.icon(
                onPressed: _openOutlineAndBookmarksSheet,
                icon: const Icon(Icons.format_list_bulleted, size: 17, color: Colors.blueAccent),
                label: Text(
                  '목차/책갈피 (${_outline.length + _bookmarks.length})',
                  style: const TextStyle(fontSize: 12, color: Colors.white),
                ),
              ),
              TextButton.icon(
                onPressed: _openSettingsSheet,
                icon: const Icon(Icons.settings_outlined, size: 17, color: Colors.tealAccent),
                label: const Text('뷰어 설정', style: TextStyle(fontSize: 12, color: Colors.white)),
              ),
              TextButton.icon(
                onPressed: _hasNextBook
                    ? () => _switchBook(_pdfSiblings[_currentSiblingIndex + 1])
                    : null,
                icon: const Icon(Icons.fast_forward, size: 17),
                label: const Text('다음 권', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
