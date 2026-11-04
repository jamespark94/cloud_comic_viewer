import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:photo_view/photo_view.dart';
import 'package:provider/provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../../models/ebook_content.dart';
import '../../models/media_item.dart';
import '../../models/viewer_settings.dart';
import '../../services/account_manager.dart';
import '../../services/cloud_history_sync_service.dart';
import '../../services/cloud_service_interface.dart';
import '../../services/comic_cache_manager.dart';
import '../../services/epub_parser_service.dart';
import '../../services/reading_history_service.dart';
import '../../services/thumbnail_service.dart';
import '../../services/txt_parser_service.dart';
import '../../services/viewer_settings_service.dart';
import '../../utils/natural_sort_utils.dart';
import '../../utils/text_encoding_utils.dart';
import '../widgets/ebook_settings_sheet.dart';
import '../widgets/ebook_toc_drawer.dart';

class _VirtualPage {
  final int index;
  final int chapterIndex;
  final String chapterTitle;
  final List<EbookBlock> blocks;
  final int startCharOffset;
  final int endCharOffset;

  const _VirtualPage({
    required this.index,
    required this.chapterIndex,
    required this.chapterTitle,
    required this.blocks,
    required this.startCharOffset,
    required this.endCharOffset,
  });
}

class EbookReaderScreen extends StatefulWidget {
  final MediaItem item;
  final CloudService service;
  final List<MediaItem>? folderSiblings;
  final String? parentFolderId;
  final int? initialCharOffset;
  final int? initialPageIndex;

  const EbookReaderScreen({
    super.key,
    required this.item,
    required this.service,
    this.folderSiblings,
    this.parentFolderId,
    this.initialCharOffset,
    this.initialPageIndex,
  });

  @override
  State<EbookReaderScreen> createState() => _EbookReaderScreenState();
}

class _EbookReaderScreenState extends State<EbookReaderScreen> {
  bool _isLoading = true;
  String? _errorMessage;
  double _downloadProgress = 0.0;
  String _statusText = '전자책 데이터를 불러오는 중입니다...';

  Uint8List? _rawBytes;
  EbookDocument? _document;
  String? _forcedEncoding;
  String? _coverThumbPath;

  late MediaItem _currentItem;
  List<MediaItem> _ebookSiblings = [];
  List<EbookBookmark> _bookmarks = [];

  // 현재 읽고 있는 위치 상태
  int _currentCharOffset = 0;
  int _currentChapterIndex = 0;
  int _currentPageIndex = 0;
  bool _showControls = false;

  // 페이지 넘김 모드용 상태
  List<_VirtualPage> _virtualPages = [];
  PageController? _pageController;
  String _lastLayoutSignature = '';

  // 웹소설 상하 스크롤 모드용 컨트롤러
  final ItemScrollController _itemScrollController = ItemScrollController();
  final ItemPositionsListener _itemPositionsListener = ItemPositionsListener.create();

  // 키보드 포커스
  final FocusNode _focusNode = FocusNode();

  String? _toastMessage;
  Timer? _toastTimer;

  @override
  void initState() {
    super.initState();
    _currentItem = widget.item;
    _initSiblings();
    _setupScrollListener();
    _loadBook(
      initialCharOffset: widget.initialCharOffset,
      initialPageIndex: widget.initialPageIndex,
    );
  }

  void _initSiblings() {
    final siblings = widget.folderSiblings ?? [];
    _ebookSiblings = siblings
        .where((it) => !it.isFolder && (it.isTxt || it.isEpub))
        .toList()
      ..sort((a, b) => NaturalSortUtils.compare(a.name, b.name));
  }

  int get _currentSiblingIndex =>
      _ebookSiblings.indexWhere((it) => it.id == _currentItem.id);

  bool get _hasPrevBook => _currentSiblingIndex > 0;
  bool get _hasNextBook =>
      _currentSiblingIndex != -1 && _currentSiblingIndex < _ebookSiblings.length - 1;

  @override
  void dispose() {
    _toastTimer?.cancel();
    _pageController?.dispose();
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

  void _setupScrollListener() {
    _itemPositionsListener.itemPositions.addListener(() {
      final doc = _document;
      if (doc == null || doc.allBlocks.isEmpty) return;
      final settings = ViewerSettingsService.instance.settings;
      if (settings.ebookPageMode != EbookPageMode.scroll) return;

      final positions = _itemPositionsListener.itemPositions.value;
      if (positions.isEmpty) return;

      final firstVisible = positions
          .where((p) => p.itemTrailingEdge > 0)
          .reduce((a, b) => a.index < b.index ? a : b);

      final blockIdx = firstVisible.index.clamp(0, doc.allBlocks.length - 1);
      final block = doc.allBlocks[blockIdx];
      if ((block.startCharOffset - _currentCharOffset).abs() > 120) {
        _currentCharOffset = block.startCharOffset;
        _updateChapterFromOffset(_currentCharOffset);
        _saveReadingHistory();
        if (mounted) setState(() {});
      }
    });
  }

  Future<void> _loadBook({
    int? initialCharOffset,
    int? initialPageIndex,
    String? forceEncoding,
  }) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _downloadProgress = 0.0;
      _statusText = '\'${_currentItem.name}\' 파일을 준비하고 있습니다...';
    });

    try {
      // 기존 히스토리 확인
      final existingHistory = ReadingHistoryService.instance.getHistory(_currentItem.id);
      _bookmarks = List<EbookBookmark>.from(existingHistory?.bookmarks ?? const []);
      _coverThumbPath = existingHistory?.coverThumbnailUrl;

      // 1. 바이트 다운로드 (이미 메모리에 있고 인코딩만 재변경하는 경우는 재사용)
      if (_rawBytes == null || forceEncoding == null) {
        _rawBytes = await ComicCacheManager.instance.loadOrDownloadComicBytes(
          widget.service,
          _currentItem,
          onProgress: (received, total) {
            if (!mounted) return;
            if (total > 0) {
              setState(() {
                _downloadProgress = (received / total).clamp(0.0, 1.0);
                _statusText =
                    '다운로드 중... ${(_downloadProgress * 100).toStringAsFixed(0)}%';
              });
            }
          },
        );
      }

      if (!mounted) return;
      setState(() => _statusText = '본문 및 목차를 분석하고 있습니다...');

      // 2. 포맷에 맞게 파싱
      EbookDocument doc;
      if (_currentItem.isEpub) {
        doc = await EpubParserService.parseEpubBytes(
          bytes: _rawBytes!,
          fallbackTitle: _currentItem.name,
        );
        // EPUB 표지 이미지 썸네일 저장
        if (doc.coverBytes != null) {
          final savedThumb = await ThumbnailService.saveCoverThumbnail(
            _currentItem.id,
            doc.coverBytes!,
          );
          if (savedThumb != null) {
            _coverThumbPath = savedThumb;
          }
        }
      } else {
        doc = await TxtParserService.parseTxtBytes(
          bytes: _rawBytes!,
          title: _currentItem.name,
          forceEncoding: forceEncoding ?? _forcedEncoding,
        );
      }

      // 3. 시작 문자 오프셋 결정
      int targetOffset = 0;
      if (initialCharOffset != null && initialCharOffset > 0) {
        targetOffset = initialCharOffset;
      } else if (existingHistory?.charOffset != null && existingHistory!.charOffset! > 0) {
        targetOffset = existingHistory.charOffset!;
      } else if (initialPageIndex != null &&
          existingHistory != null &&
          existingHistory.totalPages > 1) {
        final ratio = (initialPageIndex / existingHistory.totalPages).clamp(0.0, 1.0);
        targetOffset = (ratio * doc.totalCharacters).round();
      }

      _document = doc;
      _currentCharOffset = targetOffset.clamp(0, math.max(0, doc.totalCharacters - 1));
      _lastLayoutSignature = '';
      _updateChapterFromOffset(_currentCharOffset);

      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });

      // 스크롤 모드일 때 초기 위치 점프
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _jumpToCurrentOffsetInScrollMode();
        _saveReadingHistory();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = '이북 열기 실패: $e';
      });
    }
  }

  void _updateChapterFromOffset(int charOffset) {
    final doc = _document;
    if (doc == null || doc.chapters.isEmpty) return;

    for (int i = doc.chapters.length - 1; i >= 0; i--) {
      if (charOffset >= doc.chapters[i].startCharOffset) {
        _currentChapterIndex = i;
        return;
      }
    }
    _currentChapterIndex = 0;
  }

  /// 화면 크기 및 폰트/줄간격 설정에 맞춰 전체 블록을 가상 페이지(`_VirtualPage`) 단위로 분할합니다.
  void _ensureVirtualPagination(Size viewportSize, ViewerSettings s) {
    final doc = _document;
    if (doc == null) return;

    final sig =
        '${viewportSize.width.round()}x${viewportSize.height.round()}_${s.ebookFontSize}_${s.ebookLineHeight}_${s.ebookParagraphSpacing}_${s.ebookHorizontalMargin}_${s.ebookVerticalMargin}_${s.ebookFontFamily}_${s.ebookFirstLineIndent}_${doc.totalCharacters}';

    if (_lastLayoutSignature == sig && _virtualPages.isNotEmpty) {
      return;
    }
    _lastLayoutSignature = sig;

    final availWidth = math.max(120.0, viewportSize.width - (s.ebookHorizontalMargin * 2));
    // 상단 여백 + 하단 마이크로 상태바(28px) 제외한 가용 높이
    final availHeight = math.max(160.0, viewportSize.height - (s.ebookVerticalMargin * 2) - 32);

    // 한 줄에 들어가는 평균 글자 수 및 한 페이지 최대 줄 수 계산
    final charWidth = s.ebookFontSize * 0.92;
    final charsPerLine = math.max(10, (availWidth / charWidth).floor());
    final lineHeightPx = s.ebookFontSize * s.ebookLineHeight;

    final List<_VirtualPage> pages = [];

    for (final chapter in doc.chapters) {
      List<EbookBlock> currentBlocks = [];
      double usedHeight = 0.0;

      void flushPage() {
        if (currentBlocks.isEmpty) return;
        pages.add(
          _VirtualPage(
            index: pages.length,
            chapterIndex: chapter.index,
            chapterTitle: chapter.title,
            blocks: List<EbookBlock>.from(currentBlocks),
            startCharOffset: currentBlocks.first.startCharOffset,
            endCharOffset: currentBlocks.last.endCharOffset,
          ),
        );
        currentBlocks = [];
        usedHeight = 0.0;
      }

      for (final block in chapter.blocks) {
        if (block.type == EbookBlockType.image) {
          // 삽화 블록은 가독성을 위해 단독 페이지 또는 충분한 공간이 있을 때만 배치
          final imgHeight = availHeight * 0.65;
          if (usedHeight + imgHeight > availHeight && currentBlocks.isNotEmpty) {
            flushPage();
          }
          currentBlocks.add(block);
          usedHeight += imgHeight;
          flushPage();
          continue;
        }

        if (block.type == EbookBlockType.heading) {
          final hLines = (block.text.length / math.max(8, charsPerLine - 4)).ceil().clamp(1, 6);
          final hHeight = (hLines * lineHeightPx * 1.25) + s.ebookParagraphSpacing + 14.0;
          if (usedHeight + hHeight > availHeight && currentBlocks.isNotEmpty) {
            flushPage();
          }
          currentBlocks.add(block);
          usedHeight += hHeight;
          continue;
        }

        if (block.type == EbookBlockType.divider) {
          const divHeight = 32.0;
          if (usedHeight + divHeight > availHeight && currentBlocks.isNotEmpty) {
            flushPage();
          }
          currentBlocks.add(block);
          usedHeight += divHeight;
          continue;
        }

        // 일반 문단: 아주 긴 문단이 한 페이지를 초과할 경우 문장/글자 단위로 쪼개어 잘림 방지
        String remainingText = block.text;
        int subStartOffset = block.startCharOffset;

        while (remainingText.isNotEmpty) {
          final remainingHeight = availHeight - usedHeight;
          final availableLines = ((remainingHeight - s.ebookParagraphSpacing) / lineHeightPx).floor();

          if (availableLines <= 1 && currentBlocks.isNotEmpty) {
            flushPage();
            continue;
          }

          final maxLinesForChunk = math.max(1, availableLines);
          final neededLines = (remainingText.length / charsPerLine).ceil().clamp(1, 10000);

          if (neededLines <= maxLinesForChunk) {
            final subEnd = subStartOffset + remainingText.length;
            currentBlocks.add(
              EbookBlock(
                type: EbookBlockType.paragraph,
                text: remainingText,
                startCharOffset: subStartOffset,
                endCharOffset: subEnd,
              ),
            );
            usedHeight += (neededLines * lineHeightPx) + s.ebookParagraphSpacing;
            remainingText = '';
          } else {
            // 현재 페이지 남은 줄 수만큼 텍스트 분할
            int cutIndex = (maxLinesForChunk * charsPerLine).clamp(1, remainingText.length);
            // 단어/어절 중간이 끊기지 않도록 뒤쪽 공백 탐색
            if (cutIndex < remainingText.length) {
              final lastSpace = remainingText.lastIndexOf(' ', cutIndex);
              if (lastSpace > cutIndex * 0.7) {
                cutIndex = lastSpace + 1;
              }
            }
            final chunkText = remainingText.substring(0, cutIndex).trimRight();
            final subEnd = subStartOffset + chunkText.length;
            if (chunkText.isNotEmpty) {
              currentBlocks.add(
                EbookBlock(
                  type: EbookBlockType.paragraph,
                  text: chunkText,
                  startCharOffset: subStartOffset,
                  endCharOffset: subEnd,
                ),
              );
            }
            flushPage();
            remainingText = remainingText.substring(cutIndex).trimLeft();
            subStartOffset = subEnd;
          }
        }
      }

      flushPage();
    }

    if (pages.isEmpty) {
      pages.add(
        _VirtualPage(
          index: 0,
          chapterIndex: 0,
          chapterTitle: doc.title,
          blocks: doc.allBlocks,
          startCharOffset: 0,
          endCharOffset: doc.totalCharacters,
        ),
      );
    }

    _virtualPages = pages;

    // 현재 _currentCharOffset에 해당하는 페이지 인덱스 찾기
    int matchedPage = 0;
    for (int i = pages.length - 1; i >= 0; i--) {
      if (_currentCharOffset >= pages[i].startCharOffset) {
        matchedPage = i;
        break;
      }
    }
    _currentPageIndex = matchedPage.clamp(0, pages.length - 1);
    _currentChapterIndex = pages[_currentPageIndex].chapterIndex;

    if (_pageController == null) {
      _pageController = PageController(initialPage: _currentPageIndex);
    } else if (_pageController!.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_pageController != null && _pageController!.hasClients) {
          _pageController!.jumpToPage(_currentPageIndex);
        }
      });
    }
  }

  void _jumpToCharOffset(int targetOffset) {
    final doc = _document;
    if (doc == null) return;
    _currentCharOffset = targetOffset.clamp(0, math.max(0, doc.totalCharacters - 1));
    _updateChapterFromOffset(_currentCharOffset);

    final settings = ViewerSettingsService.instance.settings;
    if (settings.ebookPageMode == EbookPageMode.paged && _virtualPages.isNotEmpty) {
      int targetPage = 0;
      for (int i = _virtualPages.length - 1; i >= 0; i--) {
        if (_currentCharOffset >= _virtualPages[i].startCharOffset) {
          targetPage = i;
          break;
        }
      }
      _currentPageIndex = targetPage;
      _pageController?.jumpToPage(targetPage);
    } else {
      _jumpToCurrentOffsetInScrollMode();
    }

    _saveReadingHistory();
    setState(() {});
  }

  void _jumpToCurrentOffsetInScrollMode() {
    final doc = _document;
    if (doc == null || doc.allBlocks.isEmpty || !_itemScrollController.isAttached) return;

    int targetBlockIdx = 0;
    for (int i = doc.allBlocks.length - 1; i >= 0; i--) {
      if (_currentCharOffset >= doc.allBlocks[i].startCharOffset) {
        targetBlockIdx = i;
        break;
      }
    }
    _itemScrollController.jumpTo(index: targetBlockIdx);
  }

  void _nextPage() {
    final settings = ViewerSettingsService.instance.settings;
    if (settings.ebookPageMode != EbookPageMode.paged) return;
    if (_currentPageIndex < _virtualPages.length - 1) {
      _pageController?.nextPage(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    } else if (_hasNextBook) {
      _switchBook(_ebookSiblings[_currentSiblingIndex + 1]);
    } else {
      _showToast('마지막 페이지입니다.');
    }
  }

  void _prevPage() {
    final settings = ViewerSettingsService.instance.settings;
    if (settings.ebookPageMode != EbookPageMode.paged) return;
    if (_currentPageIndex > 0) {
      _pageController?.previousPage(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    } else if (_hasPrevBook) {
      _switchBook(_ebookSiblings[_currentSiblingIndex - 1]);
    } else {
      _showToast('첫 페이지입니다.');
    }
  }

  void _switchBook(MediaItem nextItem) {
    _rawBytes = null;
    _document = null;
    _virtualPages = [];
    _currentItem = nextItem;
    _showToast('\'${nextItem.name}\' 열기');
    _loadBook(initialCharOffset: 0, initialPageIndex: 0);
  }

  void _toggleBookmarkAtCurrentPosition() {
    final doc = _document;
    if (doc == null) return;

    // 현재 페이지 근처에 이미 북마크가 있는지 확인 (오차 150자 이내)
    final existingIdx = _bookmarks.indexWhere(
      (b) => (b.charOffset - _currentCharOffset).abs() < 150,
    );

    if (existingIdx != -1) {
      setState(() {
        _bookmarks.removeAt(existingIdx);
      });
      ReadingHistoryService.instance.updateBookmarks(_currentItem.id, _bookmarks);
      _showToast('책갈피가 해제되었습니다.');
      return;
    }

    // 현재 위치의 문장 스니펫 추출
    String snippet = _currentItem.name;
    for (final b in doc.allBlocks) {
      if (b.endCharOffset >= _currentCharOffset && b.text.isNotEmpty) {
        snippet = b.text.length > 80 ? '${b.text.substring(0, 80)}...' : b.text;
        break;
      }
    }

    final chapTitle = doc.chapters.isNotEmpty &&
            _currentChapterIndex < doc.chapters.length
        ? doc.chapters[_currentChapterIndex].title
        : '';

    final newBm = EbookBookmark(
      id: 'bm_${DateTime.now().millisecondsSinceEpoch}',
      chapterIndex: _currentChapterIndex,
      chapterTitle: chapTitle,
      charOffset: _currentCharOffset,
      snippet: snippet,
      createdAt: DateTime.now(),
    );

    setState(() {
      _bookmarks.add(newBm);
      _bookmarks.sort((a, b) => a.charOffset.compareTo(b.charOffset));
    });
    _saveReadingHistory();
    _showToast('현재 위치에 책갈피를 꽂았습니다.');
  }

  bool get _isCurrentPositionBookmarked =>
      _bookmarks.any((b) => (b.charOffset - _currentCharOffset).abs() < 150);

  void _saveReadingHistory() {
    final doc = _document;
    if (doc == null) return;

    final totalPages = _virtualPages.isNotEmpty
        ? _virtualPages.length
        : math.max(1, (doc.totalCharacters / 800).ceil());
    final pageIdx = _virtualPages.isNotEmpty
        ? _currentPageIndex
        : ((_currentCharOffset / math.max(1, doc.totalCharacters)) * (totalPages - 1)).round();

    final chapTitle = doc.chapters.isNotEmpty &&
            _currentChapterIndex < doc.chapters.length
        ? doc.chapters[_currentChapterIndex].title
        : null;

    ReadingHistoryService.instance.updateProgress(
      id: _currentItem.id,
      accountId: widget.service.account.id,
      accountName: widget.service.account.name,
      cloudType: widget.service.account.type,
      title: _currentItem.name,
      parentFolderId: widget.parentFolderId ?? _currentItem.parentId,
      pageIndex: pageIdx.clamp(0, math.max(0, totalPages - 1)),
      totalPages: totalPages,
      coverThumbnailUrl: _coverThumbPath,
      bookType: _currentItem.isEpub ? 'epub' : 'txt',
      chapterIndex: _currentChapterIndex,
      chapterTitle: chapTitle,
      charOffset: _currentCharOffset,
      bookmarks: _bookmarks,
    );

    if (mounted) {
      final accountMgr = context.read<AccountManager>();
      CloudHistorySyncService.instance.scheduleAutoPush(accountMgr);
    }
  }

  void _openTocSheet({int initialTab = 0}) {
    final doc = _document;
    if (doc == null) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => EbookTocSheet(
        chapters: doc.chapters,
        currentChapterIndex: _currentChapterIndex,
        bookmarks: _bookmarks,
        allBlocks: doc.allBlocks,
        totalCharacters: doc.totalCharacters,
        initialTabIndex: initialTab,
        onSelectChapter: (chap) {
          _jumpToCharOffset(chap.startCharOffset);
          _showToast(chap.title);
        },
        onSelectBookmark: (bm) {
          _jumpToCharOffset(bm.charOffset);
        },
        onDeleteBookmark: (bm) {
          setState(() {
            _bookmarks.removeWhere((e) => e.id == bm.id);
          });
          _saveReadingHistory();
        },
        onSelectSearchResult: (res) {
          _jumpToCharOffset(res.charOffset);
        },
      ),
    );
  }

  void _openSettingsSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const EbookSettingsSheet(isPdf: false),
    );
  }

  void _openEncodingMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1F2B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) {
        final currentEnc = _forcedEncoding ?? _document?.encoding ?? 'AUTO';
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: Row(
                  children: [
                    Icon(Icons.translate, color: Colors.blueAccent, size: 20),
                    SizedBox(width: 8),
                    Text(
                      '텍스트 인코딩 변경 (한글 깨짐 보정)',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Colors.white12),
              ...TextEncodingUtils.supportedEncodings.map((enc) {
                final selected = currentEnc.toUpperCase().startsWith(enc);
                return ListTile(
                  dense: true,
                  leading: Icon(
                    selected ? Icons.radio_button_checked : Icons.radio_button_off,
                    color: selected ? Colors.blueAccent : Colors.white38,
                    size: 20,
                  ),
                  title: Text(
                    enc == 'AUTO'
                        ? '자동 감지 (현재: ${_document?.encoding ?? "UTF-8"})'
                        : enc,
                    style: TextStyle(
                      fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                      color: selected ? Colors.blueAccent : Colors.white,
                    ),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _forcedEncoding = enc == 'AUTO' ? null : enc;
                    _loadBook(
                      initialCharOffset: _currentCharOffset,
                      forceEncoding: enc,
                    );
                  },
                );
              }),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  void _openFullScreenImage(Uint8List imgBytes) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (ctx) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black87,
            title: const Text('삽화 확대 보기', style: TextStyle(fontSize: 15)),
          ),
          body: PhotoView(
            imageProvider: MemoryImage(imgBytes),
            minScale: PhotoViewComputedScale.contained,
            maxScale: PhotoViewComputedScale.covered * 3.5,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ViewerSettingsService>(
      builder: (context, settingsSvc, _) {
        final s = settingsSvc.settings;
        final bgColor = s.theme.color;
        final textColor = s.theme.textColor;

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
            backgroundColor: bgColor,
            body: SafeArea(
              child: Stack(
                children: [
                  // 1. 본문 영역
                  _buildReaderBody(context, s, textColor),

                  // 2. 하단 고정 마이크로 상태바 (챕터명 • 진도율 • 시계 • 페이지)
                  if (!_isLoading && _errorMessage == null && _document != null)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: _buildMicroStatusBar(s, textColor),
                    ),

                  // 3. 상단/하단 플로팅 HUD 컨트롤 바
                  if (_showControls && !_isLoading && _document != null) ...[
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: _buildTopControlBar(context),
                    ),
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: _buildBottomControlBar(context, s),
                    ),
                  ],

                  // 4. 토스트 메시지 오버레이
                  if (_toastMessage != null)
                    Positioned(
                      bottom: _showControls ? 140 : 48,
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

  Widget _buildReaderBody(BuildContext context, ViewerSettings s, Color textColor) {
    if (_isLoading) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Colors.blueAccent),
              const SizedBox(height: 20),
              Text(
                _statusText,
                textAlign: TextAlign.center,
                style: TextStyle(color: textColor, fontSize: 14),
              ),
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
              const Icon(Icons.error_outline, color: Colors.redAccent, size: 52),
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: TextStyle(color: textColor, fontSize: 14),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('돌아가기'),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    onPressed: () => _loadBook(initialCharOffset: _currentCharOffset),
                    icon: const Icon(Icons.refresh),
                    label: const Text('다시 시도'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    final doc = _document!;

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportSize = Size(constraints.maxWidth, constraints.maxHeight);

        if (s.ebookPageMode == EbookPageMode.paged) {
          _ensureVirtualPagination(viewportSize, s);
          return _buildPagedView(viewportSize, s, textColor);
        } else {
          return _buildScrollView(doc, s, textColor);
        }
      },
    );
  }

  /// 1. 좌우 가상 페이지네이션 뷰
  Widget _buildPagedView(Size viewportSize, ViewerSettings s, Color textColor) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) {
        final dx = details.localPosition.dx;
        final w = viewportSize.width;
        if (dx < w * 0.30) {
          if (_showControls) {
            setState(() => _showControls = false);
          } else {
            _prevPage();
          }
        } else if (dx > w * 0.70) {
          if (_showControls) {
            setState(() => _showControls = false);
          } else {
            _nextPage();
          }
        } else {
          setState(() => _showControls = !_showControls);
        }
      },
      child: PageView.builder(
        controller: _pageController,
        itemCount: _virtualPages.length,
        onPageChanged: (index) {
          setState(() {
            _currentPageIndex = index;
            final vp = _virtualPages[index];
            _currentCharOffset = vp.startCharOffset;
            _currentChapterIndex = vp.chapterIndex;
          });
          _saveReadingHistory();
        },
        itemBuilder: (context, index) {
          final page = _virtualPages[index];
          return Padding(
            padding: EdgeInsets.fromLTRB(
              s.ebookHorizontalMargin,
              s.ebookVerticalMargin,
              s.ebookHorizontalMargin,
              s.ebookVerticalMargin + 28,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: page.blocks
                  .map((b) => _buildBlockWidget(b, s, textColor, isPaged: true))
                  .toList(),
            ),
          );
        },
      ),
    );
  }

  /// 2. 상하 웹소설 연속 스크롤 뷰
  Widget _buildScrollView(EbookDocument doc, ViewerSettings s, Color textColor) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapUp: (details) {
        final dy = details.localPosition.dy;
        final h = MediaQuery.of(context).size.height;
        if (dy > h * 0.25 && dy < h * 0.75) {
          setState(() => _showControls = !_showControls);
        }
      },
      child: ScrollablePositionedList.builder(
        itemScrollController: _itemScrollController,
        itemPositionsListener: _itemPositionsListener,
        padding: EdgeInsets.fromLTRB(
          s.ebookHorizontalMargin,
          s.ebookVerticalMargin + 12,
          s.ebookHorizontalMargin,
          s.ebookVerticalMargin + 56,
        ),
        itemCount: doc.allBlocks.length,
        itemBuilder: (context, index) {
          final block = doc.allBlocks[index];
          return _buildBlockWidget(block, s, textColor, isPaged: false);
        },
      ),
    );
  }

  Widget _buildBlockWidget(
    EbookBlock block,
    ViewerSettings s,
    Color textColor, {
    required bool isPaged,
  }) {
    final fontFamily = s.ebookFontFamily == 'default' ? null : s.ebookFontFamily;

    switch (block.type) {
      case EbookBlockType.heading:
        return Padding(
          padding: EdgeInsets.only(
            top: isPaged ? 6 : 18,
            bottom: s.ebookParagraphSpacing + 4,
          ),
          child: Text(
            block.text,
            style: TextStyle(
              color: textColor,
              fontSize: s.ebookFontSize * 1.25,
              fontWeight: FontWeight.bold,
              height: s.ebookLineHeight,
              fontFamily: fontFamily,
            ),
          ),
        );

      case EbookBlockType.divider:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Center(
            child: Text(
              '• • •',
              style: TextStyle(color: textColor.withAlpha(120), fontSize: s.ebookFontSize),
            ),
          ),
        );

      case EbookBlockType.image:
        final imgBytes = block.imageKey != null ? _document?.images[block.imageKey!] : null;
        if (imgBytes == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: GestureDetector(
            onTap: () => _openFullScreenImage(imgBytes),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * (isPaged ? 0.62 : 0.72),
                ),
                child: Image.memory(
                  imgBytes,
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
        );

      case EbookBlockType.paragraph:
        final displayText = s.ebookFirstLineIndent ? '　${block.text}' : block.text;
        return Padding(
          padding: EdgeInsets.only(bottom: s.ebookParagraphSpacing),
          child: Text(
            displayText,
            textAlign: s.ebookJustifyText ? TextAlign.justify : TextAlign.start,
            style: TextStyle(
              color: textColor,
              fontSize: s.ebookFontSize,
              height: s.ebookLineHeight,
              fontFamily: fontFamily,
            ),
          ),
        );
    }
  }

  Widget _buildMicroStatusBar(ViewerSettings s, Color textColor) {
    final doc = _document!;
    final chapTitle = doc.chapters.isNotEmpty && _currentChapterIndex < doc.chapters.length
        ? doc.chapters[_currentChapterIndex].title
        : doc.title;

    final progressPct = doc.totalCharacters > 0
        ? ((_currentCharOffset / doc.totalCharacters) * 100).clamp(0.0, 100.0)
        : 0.0;

    final timeStr = DateFormat('HH:mm').format(DateTime.now());
    final pageText = s.ebookPageMode == EbookPageMode.paged && _virtualPages.isNotEmpty
        ? '${_currentPageIndex + 1} / ${_virtualPages.length}p'
        : '${progressPct.toStringAsFixed(1)}%';

    return Container(
      height: 26,
      padding: EdgeInsets.symmetric(horizontal: s.ebookHorizontalMargin),
      color: s.theme.color.withAlpha(235),
      child: Row(
        children: [
          if (_isCurrentPositionBookmarked) ...[
            const Icon(Icons.bookmark, size: 13, color: Colors.amber),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Text(
              chapTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: textColor.withAlpha(150), fontSize: 11),
            ),
          ),
          if (s.showClockAndBattery) ...[
            Text(
              timeStr,
              style: TextStyle(color: textColor.withAlpha(150), fontSize: 11),
            ),
            const SizedBox(width: 10),
          ],
          if (s.showPageNumber)
            Text(
              '$pageText (${progressPct.toStringAsFixed(0)}%)',
              style: TextStyle(
                color: textColor.withAlpha(170),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTopControlBar(BuildContext context) {
    final isBookmarked = _isCurrentPositionBookmarked;
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
            tooltip: '나가기',
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
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  '${_currentItem.formatBadgeLabel} • ${_document?.encoding ?? ""}',
                  style: const TextStyle(color: Colors.blueAccent, fontSize: 11),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.search, color: Colors.white),
            tooltip: '본문 검색',
            onPressed: () => _openTocSheet(initialTab: 2),
          ),
          IconButton(
            icon: Icon(
              isBookmarked ? Icons.bookmark : Icons.bookmark_border,
              color: isBookmarked ? Colors.amber : Colors.white,
            ),
            tooltip: isBookmarked ? '책갈피 해제' : '현재 위치 책갈피 추가',
            onPressed: _toggleBookmarkAtCurrentPosition,
          ),
          if (_currentItem.isTxt)
            IconButton(
              icon: const Icon(Icons.translate, color: Colors.white),
              tooltip: '텍스트 인코딩 변경',
              onPressed: _openEncodingMenu,
            ),
          IconButton(
            icon: const Icon(Icons.tune, color: Colors.white),
            tooltip: '조판 및 테마 설정',
            onPressed: _openSettingsSheet,
          ),
        ],
      ),
    );
  }

  Widget _buildBottomControlBar(BuildContext context, ViewerSettings s) {
    final doc = _document!;
    final isPaged = s.ebookPageMode == EbookPageMode.paged && _virtualPages.isNotEmpty;
    final maxSlider = isPaged
        ? math.max(1.0, (_virtualPages.length - 1).toDouble())
        : math.max(1.0, doc.totalCharacters.toDouble());
    final currentSlider = isPaged
        ? _currentPageIndex.toDouble().clamp(0.0, maxSlider)
        : _currentCharOffset.toDouble().clamp(0.0, maxSlider);

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: const Color(0xFF141822).withAlpha(242),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        border: const Border(top: BorderSide(color: Colors.white12)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 1. 페이지/진도 슬라이더
          Row(
            children: [
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.skip_previous, color: Colors.white70, size: 20),
                tooltip: '이전 챕터',
                onPressed: _currentChapterIndex > 0
                    ? () {
                        final prevChap = doc.chapters[_currentChapterIndex - 1];
                        _jumpToCharOffset(prevChap.startCharOffset);
                        _showToast(prevChap.title);
                      }
                    : null,
              ),
              Expanded(
                child: SliderTheme(
                  data: const SliderThemeData(
                    trackHeight: 3.5,
                    thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7),
                  ),
                  child: Slider(
                    value: currentSlider,
                    min: 0.0,
                    max: maxSlider,
                    activeColor: Colors.blueAccent,
                    inactiveColor: Colors.white24,
                    onChanged: (val) {
                      if (isPaged) {
                        final targetPage = val.round().clamp(0, _virtualPages.length - 1);
                        _pageController?.jumpToPage(targetPage);
                      } else {
                        _jumpToCharOffset(val.round());
                      }
                    },
                  ),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.skip_next, color: Colors.white70, size: 20),
                tooltip: '다음 챕터',
                onPressed: _currentChapterIndex < doc.chapters.length - 1
                    ? () {
                        final nextChap = doc.chapters[_currentChapterIndex + 1];
                        _jumpToCharOffset(nextChap.startCharOffset);
                        _showToast(nextChap.title);
                      }
                    : null,
              ),
            ],
          ),
          const SizedBox(height: 4),
          // 2. 하단 액션 버튼 바 (이전 권 / 목차 / 책갈피 / 글자설정 / 다음 권)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              TextButton.icon(
                onPressed: _hasPrevBook
                    ? () => _switchBook(_ebookSiblings[_currentSiblingIndex - 1])
                    : null,
                icon: const Icon(Icons.fast_rewind, size: 17),
                label: const Text('이전 권', style: TextStyle(fontSize: 12)),
              ),
              TextButton.icon(
                onPressed: () => _openTocSheet(initialTab: 0),
                icon: const Icon(Icons.format_list_bulleted, size: 17, color: Colors.blueAccent),
                label: Text(
                  '목차 (${doc.chapters.length})',
                  style: const TextStyle(fontSize: 12, color: Colors.white),
                ),
              ),
              TextButton.icon(
                onPressed: () => _openTocSheet(initialTab: 1),
                icon: const Icon(Icons.bookmarks_outlined, size: 17, color: Colors.amber),
                label: Text(
                  '책갈피 (${_bookmarks.length})',
                  style: const TextStyle(fontSize: 12, color: Colors.white),
                ),
              ),
              TextButton.icon(
                onPressed: _openSettingsSheet,
                icon: const Icon(Icons.text_fields, size: 17, color: Colors.tealAccent),
                label: const Text(
                  '조판/테마',
                  style: TextStyle(fontSize: 12, color: Colors.white),
                ),
              ),
              TextButton.icon(
                onPressed: _hasNextBook
                    ? () => _switchBook(_ebookSiblings[_currentSiblingIndex + 1])
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
