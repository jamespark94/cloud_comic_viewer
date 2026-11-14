import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../models/comic_page.dart';

class ComicThumbnailSheet extends StatefulWidget {
  final List<ComicPage> pages;
  final int currentPageIndex;
  final ValueChanged<int> onPageSelected;

  static const int _crossAxisCount = 3;
  static const double _childAspectRatio = 0.7;
  static const double _crossAxisSpacing = 10.0;
  static const double _mainAxisSpacing = 10.0;
  static const double _gridPadding = 12.0;

  const ComicThumbnailSheet({
    super.key,
    required this.pages,
    required this.currentPageIndex,
    required this.onPageSelected,
  });

  static double computeInitialScrollOffset({
    required int pageCount,
    required int currentPageIndex,
    required double viewportWidth,
    required double viewportHeight,
  }) {
    if (pageCount <= 0 || viewportWidth <= 0 || viewportHeight <= 0) {
      return 0.0;
    }

    final clampedIndex = currentPageIndex.clamp(0, pageCount - 1);
    final usableWidth = viewportWidth -
        (_gridPadding * 2) -
        (_crossAxisSpacing * (_crossAxisCount - 1));
    if (usableWidth <= 0) return 0.0;

    final itemWidth = usableWidth / _crossAxisCount;
    final itemHeight = itemWidth / _childAspectRatio;
    final rowStride = itemHeight + _mainAxisSpacing;

    final totalRows = (pageCount + _crossAxisCount - 1) ~/ _crossAxisCount;
    final totalContentHeight = (_gridPadding * 2) +
        (totalRows * itemHeight) +
        ((totalRows - 1) * _mainAxisSpacing);
    final maxScrollExtent = math.max(0.0, totalContentHeight - viewportHeight);
    if (maxScrollExtent <= 0) return 0.0;

    final currentRow = clampedIndex ~/ _crossAxisCount;
    final rowTop = _gridPadding + (currentRow * rowStride);
    final rowCenter = rowTop + (itemHeight / 2.0);
    final targetOffset = rowCenter - (viewportHeight / 2.0);
    return targetOffset.clamp(0.0, maxScrollExtent);
  }

  static Future<void> show(
    BuildContext context, {
    required List<ComicPage> pages,
    required int currentPageIndex,
    required ValueChanged<int> onPageSelected,
  }) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF14171F),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: ComicThumbnailSheet(
          pages: pages,
          currentPageIndex: currentPageIndex,
          onPageSelected: (index) {
            Navigator.pop(context);
            onPageSelected(index);
          },
        ),
      ),
    );
  }

  @override
  State<ComicThumbnailSheet> createState() => _ComicThumbnailSheetState();
}

class _ComicThumbnailSheetState extends State<ComicThumbnailSheet> {
  ScrollController? _scrollController;

  @override
  void dispose() {
    _scrollController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 40,
          height: 4,
          margin: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white24,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '전체 페이지 목록 (${widget.pages.length}p)',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              Text(
                '현재 ${widget.currentPageIndex + 1}p',
                style: const TextStyle(
                  fontSize: 13,
                  color: Colors.blueAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
        const Divider(color: Colors.white12),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              _scrollController ??= ScrollController(
                initialScrollOffset: ComicThumbnailSheet.computeInitialScrollOffset(
                  pageCount: widget.pages.length,
                  currentPageIndex: widget.currentPageIndex,
                  viewportWidth: constraints.maxWidth,
                  viewportHeight: constraints.maxHeight,
                ),
              );

              return GridView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.all(ComicThumbnailSheet._gridPadding),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: ComicThumbnailSheet._crossAxisCount,
                  childAspectRatio: ComicThumbnailSheet._childAspectRatio,
                  crossAxisSpacing: ComicThumbnailSheet._crossAxisSpacing,
                  mainAxisSpacing: ComicThumbnailSheet._mainAxisSpacing,
                ),
                itemCount: widget.pages.length,
                itemBuilder: (context, index) {
                  final page = widget.pages[index];
                  final isCurrent = index == widget.currentPageIndex;

                  return GestureDetector(
                    onTap: () => widget.onPageSelected(index),
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E212B),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isCurrent ? Colors.blueAccent : Colors.white12,
                          width: isCurrent ? 2.5 : 1,
                        ),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          // 이미지 렌더링 (바이트 로드)
                          FutureBuilder(
                            future: page.getBytes(),
                            builder: (context, snapshot) {
                              if (snapshot.hasData) {
                                return Image.memory(
                                  snapshot.data!,
                                  fit: BoxFit.cover,
                                  errorBuilder: (context, error, stackTrace) => const Center(
                                    child: Icon(Icons.broken_image, color: Colors.white24),
                                  ),
                                );
                              }
                              return const Center(
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                              );
                            },
                          ),
                          // 페이지 번호 뱃지
                          Positioned(
                            bottom: 0,
                            left: 0,
                            right: 0,
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              color: Colors.black.withAlpha(180),
                              child: Text(
                                '${index + 1}p',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: isCurrent ? Colors.blueAccent : Colors.white70,
                                  fontSize: 11,
                                  fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                                ),
                              ),
                            ),
                          ),
                          if (isCurrent)
                            Positioned(
                              top: 6,
                              right: 6,
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: const BoxDecoration(
                                  color: Colors.blueAccent,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.check, size: 12, color: Colors.white),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
