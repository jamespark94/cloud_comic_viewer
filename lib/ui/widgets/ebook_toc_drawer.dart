import 'package:flutter/material.dart';
import '../../models/ebook_content.dart';

class EbookTocSheet extends StatefulWidget {
  final List<EbookChapter> chapters;
  final int currentChapterIndex;
  final List<EbookBookmark> bookmarks;
  final List<EbookBlock> allBlocks;
  final int totalCharacters;
  final int initialTabIndex;
  final ValueChanged<EbookChapter> onSelectChapter;
  final ValueChanged<EbookBookmark> onSelectBookmark;
  final ValueChanged<EbookBookmark> onDeleteBookmark;
  final ValueChanged<EbookSearchResult> onSelectSearchResult;

  const EbookTocSheet({
    super.key,
    required this.chapters,
    required this.currentChapterIndex,
    required this.bookmarks,
    required this.allBlocks,
    required this.totalCharacters,
    this.initialTabIndex = 0,
    required this.onSelectChapter,
    required this.onSelectBookmark,
    required this.onDeleteBookmark,
    required this.onSelectSearchResult,
  });

  @override
  State<EbookTocSheet> createState() => _EbookTocSheetState();
}

class _EbookTocSheetState extends State<EbookTocSheet> with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final TextEditingController _searchController = TextEditingController();
  List<EbookSearchResult> _searchResults = [];
  bool _hasSearched = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 3,
      vsync: this,
      initialIndex: widget.initialTabIndex.clamp(0, 2),
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _runSearch(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _searchResults = [];
        _hasSearched = false;
      });
      return;
    }

    final lowerQ = trimmed.toLowerCase();
    final List<EbookSearchResult> results = [];

    for (int i = 0; i < widget.allBlocks.length; i++) {
      final block = widget.allBlocks[i];
      if (block.type == EbookBlockType.image || block.text.isEmpty) continue;

      final lowerText = block.text.toLowerCase();
      int matchIdx = lowerText.indexOf(lowerQ);
      if (matchIdx != -1) {
        // 해당 블록이 속한 챕터 찾기
        int chapIdx = 0;
        String chapTitle = '';
        for (final c in widget.chapters) {
          if (block.startCharOffset >= c.startCharOffset && block.startCharOffset <= c.endCharOffset) {
            chapIdx = c.index;
            chapTitle = c.title;
            break;
          }
        }

        // 앞뒤 문맥 40자 스니펫 생성
        final start = (matchIdx - 25).clamp(0, block.text.length);
        final end = (matchIdx + trimmed.length + 35).clamp(0, block.text.length);
        final prefix = start > 0 ? '...' : '';
        final suffix = end < block.text.length ? '...' : '';
        final snippet = '$prefix${block.text.substring(start, end)}$suffix';

        results.add(
          EbookSearchResult(
            chapterIndex: chapIdx,
            chapterTitle: chapTitle,
            blockIndex: i,
            charOffset: block.startCharOffset + matchIdx,
            snippet: snippet,
          ),
        );

        if (results.length >= 200) break; // 최대 200건 제한으로 즉각 응답 보장
      }
    }

    setState(() {
      _searchResults = results;
      _hasSearched = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.78,
      decoration: const BoxDecoration(
        color: Color(0xFF1A1F2B),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
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
            controller: _tabController,
            indicatorColor: Colors.blueAccent,
            labelColor: Colors.blueAccent,
            unselectedLabelColor: Colors.white60,
            tabs: [
              Tab(
                icon: const Icon(Icons.format_list_bulleted, size: 18),
                text: '목차 (${widget.chapters.length})',
              ),
              Tab(
                icon: const Icon(Icons.bookmarks_outlined, size: 18),
                text: '책갈피 (${widget.bookmarks.length})',
              ),
              const Tab(
                icon: Icon(Icons.search, size: 18),
                text: '본문 검색',
              ),
            ],
          ),
          const Divider(height: 1, color: Colors.white12),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildTocTab(context),
                _buildBookmarksTab(context),
                _buildSearchTab(context),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTocTab(BuildContext context) {
    if (widget.chapters.isEmpty) {
      return const Center(
        child: Text('표시할 목차가 없습니다.', style: TextStyle(color: Colors.white54)),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: widget.chapters.length,
      separatorBuilder: (_, _) => const Divider(height: 1, color: Colors.white10),
      itemBuilder: (context, index) {
        final chap = widget.chapters[index];
        final isCurrent = index == widget.currentChapterIndex;
        final percent = widget.totalCharacters > 0
            ? ((chap.startCharOffset / widget.totalCharacters) * 100).clamp(0, 100).toStringAsFixed(0)
            : '0';

        return ListTile(
          dense: true,
          selected: isCurrent,
          selectedTileColor: Colors.blueAccent.withAlpha(30),
          leading: Icon(
            isCurrent ? Icons.play_arrow_rounded : Icons.article_outlined,
            color: isCurrent ? Colors.blueAccent : Colors.white38,
            size: 20,
          ),
          title: Text(
            chap.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
              color: isCurrent ? Colors.blueAccent : Colors.white,
            ),
          ),
          trailing: Text(
            '$percent%',
            style: TextStyle(
              fontSize: 11,
              color: isCurrent ? Colors.blueAccent : Colors.white38,
            ),
          ),
          onTap: () {
            Navigator.pop(context);
            widget.onSelectChapter(chap);
          },
        );
      },
    );
  }

  Widget _buildBookmarksTab(BuildContext context) {
    if (widget.bookmarks.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24.0),
          child: Text(
            '등록된 책갈피가 없습니다.\n뷰어 상단의 [🔖 북마크] 아이콘을 눌러 현재 위치를 저장해 보세요.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54, height: 1.5, fontSize: 13),
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: widget.bookmarks.length,
      separatorBuilder: (_, _) => const Divider(height: 1, color: Colors.white10),
      itemBuilder: (context, index) {
        final bm = widget.bookmarks[index];
        final percent = widget.totalCharacters > 0
            ? ((bm.charOffset / widget.totalCharacters) * 100).clamp(0, 100).toStringAsFixed(1)
            : '0.0';

        return ListTile(
          leading: const Icon(Icons.bookmark, color: Colors.amber, size: 22),
          title: Text(
            bm.chapterTitle.isNotEmpty ? '${bm.chapterTitle} ($percent%)' : '위치 $percent%',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.amber),
          ),
          subtitle: Text(
            bm.snippet,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: Colors.white70),
          ),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline, size: 18, color: Colors.white38),
            onPressed: () {
              widget.onDeleteBookmark(bm);
              setState(() {});
            },
          ),
          onTap: () {
            Navigator.pop(context);
            widget.onSelectBookmark(bm);
          },
        );
      },
    );
  }

  Widget _buildSearchTab(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12.0),
          child: TextField(
            controller: _searchController,
            autofocus: widget.initialTabIndex == 2,
            style: const TextStyle(fontSize: 13.5),
            decoration: InputDecoration(
              hintText: '찾을 단어 또는 문장을 입력하세요...',
              hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
              prefixIcon: const Icon(Icons.search, size: 18, color: Colors.blueAccent),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18, color: Colors.white54),
                      onPressed: () {
                        _searchController.clear();
                        _runSearch('');
                      },
                    )
                  : null,
              filled: true,
              fillColor: Colors.black26,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Colors.white12),
              ),
            ),
            onSubmitted: _runSearch,
            onChanged: (v) {
              if (v.trim().length >= 2) {
                _runSearch(v);
              }
            },
          ),
        ),
        Expanded(
          child: !_hasSearched
              ? const Center(
                  child: Text(
                    '검색어를 2글자 이상 입력하면 본문 전체에서 즉시 찾아줍니다.',
                    style: TextStyle(color: Colors.white38, fontSize: 12.5),
                  ),
                )
              : _searchResults.isEmpty
                  ? const Center(
                      child: Text(
                        '일치하는 본문 내용이 없습니다.',
                        style: TextStyle(color: Colors.white54, fontSize: 13),
                      ),
                    )
                  : ListView.separated(
                      itemCount: _searchResults.length,
                      separatorBuilder: (_, _) => const Divider(height: 1, color: Colors.white10),
                      itemBuilder: (context, index) {
                        final res = _searchResults[index];
                        final percent = widget.totalCharacters > 0
                            ? ((res.charOffset / widget.totalCharacters) * 100)
                                .clamp(0, 100)
                                .toStringAsFixed(1)
                            : '0.0';
                        return ListTile(
                          dense: true,
                          title: Text(
                            '${res.chapterTitle} • $percent%',
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: Colors.blueAccent,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Text(
                              res.snippet,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12.5, color: Colors.white),
                            ),
                          ),
                          onTap: () {
                            Navigator.pop(context);
                            widget.onSelectSearchResult(res);
                          },
                        );
                      },
                    ),
        ),
      ],
    );
  }
}
