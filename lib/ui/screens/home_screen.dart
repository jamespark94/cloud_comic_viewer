import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/cloud_account.dart';
import '../../models/comic_reading_history.dart';
import '../../models/folder_shortcut.dart';
import '../../models/media_item.dart';
import '../../services/account_manager.dart';
import '../../services/cloud_history_sync_service.dart';
import '../../services/folder_shortcut_manager.dart';
import '../../services/reading_history_service.dart';
import 'add_account_dialog.dart';
import 'browser_screen.dart';
import 'comic_viewer_screen.dart';

/// 홈 화면 탐색기 보기 모드
enum HomeViewMode {
  largeIcons('큰 아이콘', Icons.grid_view_rounded),
  smallIcons('작은 아이콘', Icons.view_comfy_alt_outlined),
  list('목록', Icons.format_list_bulleted_rounded),
  details('자세히', Icons.table_rows_outlined);

  final String label;
  final IconData icon;

  const HomeViewMode(this.label, this.icon);
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const String _prefViewModeKey = 'home_explorer_view_mode';
  HomeViewMode _viewMode = HomeViewMode.largeIcons;
  final DateFormat _dateFormat = DateFormat('yy.MM.dd HH:mm');
  DateTime? _backgroundEnteredTime;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadViewMode();
    // 앱 시작 시 백그라운드로 클라우드 히스토리 동기화 1회 자동 시도
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _silentSyncWithCloud();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _backgroundEnteredTime = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      if (_backgroundEnteredTime != null) {
        final elapsed = DateTime.now().difference(_backgroundEnteredTime!);
        if (elapsed.inSeconds >= 30) {
          debugPrint('[HomeScreen] 백그라운드 복귀 (${elapsed.inSeconds}초 경과): 클라우드 히스토리 자동 동기화 실행');
          _silentSyncWithCloud();
        }
      }
      _backgroundEnteredTime = null;
    }
  }

  Future<void> _removeHistoryItem(ComicReadingHistory history) async {
    await ReadingHistoryService.instance.removeHistory(history.id, title: history.title);
    if (mounted) {
      final accountMgr = context.read<AccountManager>();
      CloudHistorySyncService.instance.syncHistories(accountMgr, silent: true);
    }
  }

  Future<void> _clearAllHistories() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E2433),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Row(
          children: const [
            Icon(Icons.delete_sweep, color: Colors.redAccent, size: 24),
            SizedBox(width: 8),
            Text('전체 기록 삭제', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        content: const Text(
          '최근 읽은 만화 기록을 모두 삭제하시겠습니까?\n동기화된 클라우드 서버의 기록도 함께 삭제됩니다.',
          style: TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('전체 삭제', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ReadingHistoryService.instance.clearAll();
      if (mounted) {
        final accountMgr = context.read<AccountManager>();
        CloudHistorySyncService.instance.syncHistories(accountMgr, silent: true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('모든 열람 기록이 삭제되었습니다.')),
        );
      }
    }
  }

  Future<void> _loadViewMode() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefViewModeKey);
    if (saved != null) {
      final mode = HomeViewMode.values.firstWhere(
        (m) => m.name == saved,
        orElse: () => HomeViewMode.largeIcons,
      );
      if (mounted) {
        setState(() => _viewMode = mode);
      }
    }
  }

  Future<void> _changeViewMode(HomeViewMode mode) async {
    setState(() => _viewMode = mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefViewModeKey, mode.name);
  }

  Future<void> _silentSyncWithCloud() async {
    if (!mounted) return;
    final accountMgr = context.read<AccountManager>();
    await CloudHistorySyncService.instance.syncHistories(accountMgr, silent: true);
  }

  Future<void> _manualSyncWithCloud(BuildContext context) async {
    final accountMgr = context.read<AccountManager>();
    final syncService = CloudHistorySyncService.instance;
    final success = await syncService.syncHistories(accountMgr);

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(
                success ? Icons.cloud_done : Icons.cloud_off,
                color: success ? Colors.tealAccent : Colors.orangeAccent,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(syncService.lastSyncMessage ?? '동기화 완료')),
            ],
          ),
          backgroundColor: const Color(0xFF222B38),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isNarrow = screenWidth < 460;

    return AnimatedBuilder(
      animation: CloudHistorySyncService.instance,
      builder: (context, _) {
        final syncService = CloudHistorySyncService.instance;

        return Scaffold(
          appBar: AppBar(
            titleSpacing: 12,
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.auto_stories, color: Colors.blueAccent, size: 22),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    isNarrow ? '만화 뷰어' : 'Cloud Comic Viewer',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
              ],
            ),
            actions: [
              // 1. 윈도우 탐색기 스타일 보기 옵션 드롭다운 메뉴 (좁은 화면에서는 컴팩트 표시)
              PopupMenuButton<HomeViewMode>(
                tooltip: '보기 옵션 (${_viewMode.label})',
                onSelected: _changeViewMode,
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: isNarrow ? 7 : 9, vertical: 5),
                  margin: const EdgeInsets.symmetric(vertical: 9),
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(_viewMode.icon, size: 16, color: Colors.blueAccent),
                      if (!isNarrow) ...[
                        const SizedBox(width: 5),
                        Text(
                          _viewMode.label,
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      ],
                      const SizedBox(width: 2),
                      const Icon(Icons.arrow_drop_down, size: 16, color: Colors.white70),
                    ],
                  ),
                ),
                itemBuilder: (context) => HomeViewMode.values.map((mode) {
                  final isSelected = mode == _viewMode;
                  return PopupMenuItem<HomeViewMode>(
                    value: mode,
                    child: Row(
                      children: [
                        Icon(
                          mode.icon,
                          size: 18,
                          color: isSelected ? Colors.blueAccent : Colors.white70,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          mode.label,
                          style: TextStyle(
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            color: isSelected ? Colors.blueAccent : Colors.white,
                          ),
                        ),
                        const Spacer(),
                        if (isSelected) const Icon(Icons.check, size: 16, color: Colors.blueAccent),
                      ],
                    ),
                  );
                }).toList(),
              ),

              // 2. 디바이스 간 히스토리 동기화 버튼
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.all(8),
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                icon: syncService.isSyncing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blueAccent),
                      )
                    : const Icon(Icons.sync, color: Colors.blueAccent, size: 21),
                tooltip: syncService.isSyncing
                    ? '클라우드 히스토리 동기화 중...'
                    : (syncService.lastSyncTime != null
                        ? '클라우드 히스토리 동기화 (최근: ${_dateFormat.format(syncService.lastSyncTime!)})'
                        : '클라우드 히스토리 동기화'),
                onPressed: syncService.isSyncing ? null : () => _manualSyncWithCloud(context),
              ),

              // 3. 새 클라우드 계정 추가 버튼
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.all(8),
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                icon: const Icon(Icons.add_circle_outline, color: Colors.blueAccent, size: 21),
                tooltip: '새 클라우드 계정 추가',
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (_) => const AddAccountDialog(),
                  );
                },
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: () async {
              final accountMgr = context.read<AccountManager>();
              final shortcutMgr = context.read<FolderShortcutManager>();
              await accountMgr.loadAccounts();
              await shortcutMgr.loadShortcuts();
              await ReadingHistoryService.instance.loadHistories();
              await CloudHistorySyncService.instance.syncHistories(accountMgr);
            },
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 16),
              children: [
                // 1. 최근 읽은 만화책 섹션
                _buildRecentReadingSection(context),

                const SizedBox(height: 24),

                // 2. 홈 바로가기 폴더 섹션
                _buildShortcutsSection(context),

                const SizedBox(height: 24),

                // 3. 연결된 클라우드 스토리지 섹션
                _buildStorageSection(context),
              ],
            ),
          ),
        );
      },
    );
  }

  // ============================================================
  // 1. 최근 읽은 만화 섹션 (4가지 뷰 모드 지원)
  // ============================================================
  Widget _buildRecentReadingSection(BuildContext context) {
    return Consumer<ReadingHistoryService>(
      builder: (context, historyService, _) {
        final recentList = historyService.recentList;
        if (recentList.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.history, size: 20, color: Colors.blueAccent),
                      const SizedBox(width: 8),
                      Text('최근 읽은 만화 (${recentList.length})',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.delete_sweep_outlined, size: 16, color: Colors.white38),
                    label: const Text('기록 비우기', style: TextStyle(color: Colors.white38, fontSize: 12)),
                    onPressed: _clearAllHistories,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  switch (_viewMode) {
                    case HomeViewMode.largeIcons:
                      return _buildRecentLargeGrid(context, recentList, constraints.maxWidth);
                    case HomeViewMode.smallIcons:
                      return _buildRecentSmallGrid(context, recentList, constraints.maxWidth);
                    case HomeViewMode.list:
                      return _buildRecentList(context, recentList);
                    case HomeViewMode.details:
                      return _buildRecentDetailsTable(context, recentList, constraints.maxWidth);
                  }
                },
              ),
            ),
          ],
        );
      },
    );
  }

  void _openComicFromHistory(BuildContext context, ComicReadingHistory history) {
    final accountMgr = context.read<AccountManager>();
    // 타 기기에서 동기화된 계정 ID도 스마트 매칭
    final account = accountMgr.findMatchingAccount(
      accountId: history.accountId,
      cloudType: history.cloudType,
    );
    final service = accountMgr.getService(account);

    final item = MediaItem(
      id: history.id,
      name: history.title,
      parentId: history.parentFolderId,
      isFolder: false,
    );

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ComicViewerScreen(
          item: item,
          service: service,
          initialPage: history.lastPage,
        ),
      ),
    ).then((_) {
      // 뷰어 종료 시 최신 진도를 백그라운드로 클라우드에 자동 동기화 푸시
      CloudHistorySyncService.instance.syncHistories(accountMgr, silent: true);
    });
  }

  // 큰 아이콘: 만화책 표지 중심 대형 그리드
  Widget _buildRecentLargeGrid(BuildContext context, List<ComicReadingHistory> list, double width) {
    final count = (width / 160).floor().clamp(2, 6);
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: count,
        mainAxisExtent: 250,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: list.length,
      itemBuilder: (context, index) {
        final history = list[index];
        final hasThumb = history.coverThumbnailUrl != null && File(history.coverThumbnailUrl!).existsSync();

        return Stack(
          children: [
            InkWell(
              onTap: () => _openComicFromHistory(context, history),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF1B202B),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                        child: Container(
                          width: double.infinity,
                          color: Colors.black26,
                          child: hasThumb
                              ? Image.file(
                                  File(history.coverThumbnailUrl!),
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) => const Center(
                                    child: Icon(Icons.auto_stories, color: Colors.blueAccent, size: 36),
                                  ),
                                )
                              : const Center(
                                  child: Icon(Icons.auto_stories, color: Colors.blueAccent, size: 36),
                                ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            history.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            history.accountName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white38, fontSize: 10),
                          ),
                          const SizedBox(height: 6),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: history.progress,
                              minHeight: 4,
                              backgroundColor: Colors.white12,
                              valueColor: const AlwaysStoppedAnimation<Color>(Colors.blueAccent),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                '${history.lastPage + 1} / ${history.totalPages}p',
                                style: const TextStyle(color: Colors.blueAccent, fontSize: 10, fontWeight: FontWeight.bold),
                              ),
                              Text(
                                '${history.progressPercent}%',
                                style: const TextStyle(color: Colors.white54, fontSize: 10),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              top: 6,
              right: 6,
              child: Material(
                color: Colors.black54,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => _removeHistoryItem(history),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.close, size: 14, color: Colors.white70),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // 작은 아이콘: 컴팩트 카드 그리드
  Widget _buildRecentSmallGrid(BuildContext context, List<ComicReadingHistory> list, double width) {
    final count = (width / 240).floor().clamp(1, 4);
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: count,
        mainAxisExtent: 80,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: list.length,
      itemBuilder: (context, index) {
        final history = list[index];
        final hasThumb = history.coverThumbnailUrl != null && File(history.coverThumbnailUrl!).existsSync();

        return InkWell(
          onTap: () => _openComicFromHistory(context, history),
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF1B202B),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white10),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    width: 44,
                    height: 64,
                    color: Colors.black26,
                    child: hasThumb
                        ? Image.file(
                            File(history.coverThumbnailUrl!),
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const Icon(Icons.auto_stories, color: Colors.blueAccent, size: 20),
                          )
                        : const Icon(Icons.auto_stories, color: Colors.blueAccent, size: 20),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        history.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${history.accountName} · ${history.lastPage + 1}/${history.totalPages}p (${history.progressPercent}%)',
                        style: const TextStyle(color: Colors.white54, fontSize: 10),
                      ),
                      const SizedBox(height: 5),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: history.progress,
                          minHeight: 3,
                          backgroundColor: Colors.white12,
                          valueColor: const AlwaysStoppedAnimation<Color>(Colors.blueAccent),
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 16, color: Colors.white38),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  tooltip: '기록 삭제',
                  onPressed: () => _removeHistoryItem(history),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // 목록 뷰: 가로 타일 목록
  Widget _buildRecentList(BuildContext context, List<ComicReadingHistory> list) {
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: list.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final history = list[index];
        final hasThumb = history.coverThumbnailUrl != null && File(history.coverThumbnailUrl!).existsSync();

        return ListTile(
          tileColor: const Color(0xFF1B202B),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: Colors.white10),
          ),
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Container(
              width: 38,
              height: 52,
              color: Colors.black26,
              child: hasThumb
                  ? Image.file(
                      File(history.coverThumbnailUrl!),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const Icon(Icons.auto_stories, color: Colors.blueAccent, size: 18),
                    )
                  : const Icon(Icons.auto_stories, color: Colors.blueAccent, size: 18),
            ),
          ),
          title: Text(history.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${history.accountName} · 열람: ${_dateFormat.format(history.lastReadAt)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: history.progress,
                  minHeight: 3,
                  backgroundColor: Colors.white12,
                  valueColor: const AlwaysStoppedAnimation<Color>(Colors.blueAccent),
                ),
              ),
            ],
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${history.lastPage + 1}/${history.totalPages}p\n(${history.progressPercent}%)',
                textAlign: TextAlign.right,
                style: const TextStyle(color: Colors.blueAccent, fontSize: 11, fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: 4),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 18, color: Colors.white38),
                onPressed: () => _removeHistoryItem(history),
              ),
            ],
          ),
          onTap: () => _openComicFromHistory(context, history),
        );
      },
    );
  }

  // 자세히 보기: 화면 100% 폭에 맞춘 반응형 탐색기 테이블 뷰 (좌우 스크롤 불필요)
  Widget _buildRecentDetailsTable(
    BuildContext context,
    List<ComicReadingHistory> list,
    double maxWidth,
  ) {
    final showAccount = maxWidth > 500;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF1B202B),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Column(
          children: [
            // 테이블 헤더
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              color: Colors.white.withAlpha(12),
              child: Row(
                children: [
                  const Expanded(
                    flex: 5,
                    child: Text('제목 / 작품명', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white70, fontSize: 12)),
                  ),
                  if (showAccount)
                    const Expanded(
                      flex: 3,
                      child: Text('저장소', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white70, fontSize: 12)),
                    ),
                  const Expanded(
                    flex: 3,
                    child: Text('진도', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white70, fontSize: 12)),
                  ),
                  const Expanded(
                    flex: 3,
                    child: Text('열람 일시', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white70, fontSize: 12)),
                  ),
                  const SizedBox(
                    width: 32,
                    child: Center(
                      child: Text('삭제', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white70, fontSize: 11)),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Colors.white12),
            // 테이블 행 목록
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: list.length,
              separatorBuilder: (_, _) => const Divider(height: 1, color: Colors.white10),
              itemBuilder: (context, index) {
                final history = list[index];
                final hasThumb = history.coverThumbnailUrl != null && File(history.coverThumbnailUrl!).existsSync();

                return InkWell(
                  onTap: () => _openComicFromHistory(context, history),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(
                      children: [
                        // 제목 및 표지
                        Expanded(
                          flex: 5,
                          child: Row(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: Container(
                                  width: 22,
                                  height: 30,
                                  color: Colors.black26,
                                  child: hasThumb
                                      ? Image.file(File(history.coverThumbnailUrl!), fit: BoxFit.cover)
                                      : const Icon(Icons.auto_stories, color: Colors.blueAccent, size: 14),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  history.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (showAccount)
                          Expanded(
                            flex: 3,
                            child: Text(
                              history.accountName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white60, fontSize: 11),
                            ),
                          ),
                        Expanded(
                          flex: 3,
                          child: Text(
                            '${history.lastPage + 1}/${history.totalPages}p (${history.progressPercent}%)',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold, fontSize: 11),
                          ),
                        ),
                        Expanded(
                          flex: 3,
                          child: Text(
                            _dateFormat.format(history.lastReadAt),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white54, fontSize: 10),
                          ),
                        ),
                        SizedBox(
                          width: 32,
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.close, size: 16, color: Colors.white38),
                            onPressed: () => _removeHistoryItem(history),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // 2. 바로가기 폴더 섹션 (4가지 뷰 모드 지원)
  // ============================================================
  Widget _buildShortcutsSection(BuildContext context) {
    return Consumer<FolderShortcutManager>(
      builder: (context, shortcutMgr, _) {
        final shortcuts = shortcutMgr.shortcuts;
        if (shortcuts.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16.0),
              child: Row(
                children: [
                  Icon(Icons.bookmark, size: 20, color: Colors.amber),
                  SizedBox(width: 8),
                  Text('홈 바로가기 폴더', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  switch (_viewMode) {
                    case HomeViewMode.largeIcons:
                      return _buildShortcutsLargeGrid(context, shortcuts, shortcutMgr, constraints.maxWidth);
                    case HomeViewMode.smallIcons:
                      return _buildShortcutsSmallGrid(context, shortcuts, shortcutMgr, constraints.maxWidth);
                    case HomeViewMode.list:
                      return _buildShortcutsList(context, shortcuts, shortcutMgr);
                    case HomeViewMode.details:
                      return _buildShortcutsDetailsTable(context, shortcuts, shortcutMgr, constraints.maxWidth);
                  }
                },
              ),
            ),
          ],
        );
      },
    );
  }

  void _openShortcut(BuildContext context, FolderShortcut shortcut) {
    final accountMgr = context.read<AccountManager>();
    final account = accountMgr.getAccountById(shortcut.accountId) ?? AccountManager.localAccount;
    final service = accountMgr.getService(account);

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BrowserScreen(
          account: account,
          service: service,
          initialFolderId: shortcut.folderId,
          initialFolderName: shortcut.folderName,
        ),
      ),
    );
  }

  Widget _buildShortcutsLargeGrid(
    BuildContext context,
    List<FolderShortcut> shortcuts,
    FolderShortcutManager shortcutMgr,
    double width,
  ) {
    final count = (width / 160).floor().clamp(2, 6);
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: count,
        mainAxisExtent: 120,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: shortcuts.length,
      itemBuilder: (context, index) {
        final sc = shortcuts[index];
        return InkWell(
          onTap: () => _openShortcut(context, sc),
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF1B202B),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white10),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.folder_special, color: Colors.amber, size: 38),
                const SizedBox(height: 8),
                Text(
                  sc.folderName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                Text(
                  sc.accountName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white38, fontSize: 10),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildShortcutsSmallGrid(
    BuildContext context,
    List<FolderShortcut> shortcuts,
    FolderShortcutManager shortcutMgr,
    double width,
  ) {
    final count = (width / 200).floor().clamp(1, 4);
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: count,
        mainAxisExtent: 56,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: shortcuts.length,
      itemBuilder: (context, index) {
        final sc = shortcuts[index];
        return InkWell(
          onTap: () => _openShortcut(context, sc),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF1B202B),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white10),
            ),
            child: Row(
              children: [
                const Icon(Icons.folder_special, color: Colors.amber, size: 24),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        sc.folderName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                      ),
                      Text(
                        sc.accountName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white38, fontSize: 10),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 16, color: Colors.white38),
                  onPressed: () => shortcutMgr.removeShortcut(sc.id),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildShortcutsList(
    BuildContext context,
    List<FolderShortcut> shortcuts,
    FolderShortcutManager shortcutMgr,
  ) {
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: shortcuts.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final sc = shortcuts[index];
        return ListTile(
          tileColor: const Color(0xFF1B202B),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: Colors.white10),
          ),
          leading: const Icon(Icons.folder_special, color: Colors.amber, size: 28),
          title: Text(sc.folderName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          subtitle: Text(
            '${sc.accountName} · ${sc.folderPath ?? ""}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white38, fontSize: 11),
          ),
          trailing: IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 18, color: Colors.white38),
            onPressed: () => shortcutMgr.removeShortcut(sc.id),
          ),
          onTap: () => _openShortcut(context, sc),
        );
      },
    );
  }

  // 화면 폭 100% 꽉 채우는 반응형 바로가기 테이블 뷰
  Widget _buildShortcutsDetailsTable(
    BuildContext context,
    List<FolderShortcut> shortcuts,
    FolderShortcutManager shortcutMgr,
    double maxWidth,
  ) {
    final showAccount = maxWidth > 480;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF1B202B),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              color: Colors.white.withAlpha(12),
              child: Row(
                children: [
                  const Expanded(
                    flex: 5,
                    child: Text('폴더명', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white70, fontSize: 12)),
                  ),
                  if (showAccount)
                    const Expanded(
                      flex: 3,
                      child: Text('연결 계정', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white70, fontSize: 12)),
                    ),
                  const Expanded(
                    flex: 5,
                    child: Text('경로 / 식별자', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white70, fontSize: 12)),
                  ),
                  const SizedBox(
                    width: 32,
                    child: Center(
                      child: Text('삭제', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white70, fontSize: 11)),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Colors.white12),
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: shortcuts.length,
              separatorBuilder: (_, _) => const Divider(height: 1, color: Colors.white10),
              itemBuilder: (context, index) {
                final sc = shortcuts[index];
                return InkWell(
                  onTap: () => _openShortcut(context, sc),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 5,
                          child: Row(
                            children: [
                              const Icon(Icons.folder_special, color: Colors.amber, size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  sc.folderName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (showAccount)
                          Expanded(
                            flex: 3,
                            child: Text(
                              sc.accountName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white60, fontSize: 11),
                            ),
                          ),
                        Expanded(
                          flex: 5,
                          child: Text(
                            sc.folderPath ?? sc.folderId,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white38, fontSize: 11),
                          ),
                        ),
                        SizedBox(
                          width: 32,
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.close, size: 16, color: Colors.white38),
                            onPressed: () => shortcutMgr.removeShortcut(sc.id),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // 3. 연결된 클라우드 스토리지 섹션 (4가지 뷰 모드 지원)
  // ============================================================
  Widget _buildStorageSection(BuildContext context) {
    return Consumer<AccountManager>(
      builder: (context, accountMgr, _) {
        final accounts = [AccountManager.localAccount, ...accountMgr.accounts];

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16.0),
              child: Row(
                children: [
                  Icon(Icons.cloud_queue, size: 20, color: Colors.blueAccent),
                  SizedBox(width: 8),
                  Text('저장소 목록', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      switch (_viewMode) {
                        case HomeViewMode.largeIcons:
                          return _buildStorageLargeGrid(context, accounts, accountMgr, constraints.maxWidth);
                        case HomeViewMode.smallIcons:
                          return _buildStorageSmallGrid(context, accounts, accountMgr, constraints.maxWidth);
                        case HomeViewMode.list:
                          return _buildStorageList(context, accounts, accountMgr);
                        case HomeViewMode.details:
                          return _buildStorageDetailsTable(context, accounts, accountMgr, constraints.maxWidth);
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  // 새 클라우드 추가 카드 버튼
                  InkWell(
                    onTap: () {
                      showDialog(
                        context: context,
                        builder: (_) => const AddAccountDialog(),
                      );
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.blueAccent.withAlpha(100)),
                        borderRadius: BorderRadius.circular(12),
                        color: Colors.blueAccent.withAlpha(20),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.add, color: Colors.blueAccent, size: 20),
                          SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              '새 클라우드 연결 (구글, 원드라이브, Box, Dropbox, WebDAV)',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold, fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  void _openStorage(BuildContext context, CloudAccount account, AccountManager accountMgr) {
    final service = accountMgr.getService(account);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BrowserScreen(account: account, service: service),
      ),
    );
  }

  (IconData, Color) _getAccountIconAndColor(CloudType type) {
    switch (type) {
      case CloudType.local:
        return (Icons.computer, Colors.tealAccent);
      case CloudType.googleDrive:
        return (Icons.add_to_drive, Colors.orangeAccent);
      case CloudType.oneDrive:
        return (Icons.cloud, Colors.blue);
      case CloudType.box:
        return (Icons.all_inbox, Colors.indigoAccent);
      case CloudType.dropbox:
        return (Icons.folder_zip, Colors.lightBlueAccent);
      case CloudType.webDav:
        return (Icons.dns, Colors.greenAccent);
      case CloudType.terabox:
        return (Icons.cloud_circle_outlined, Colors.cyanAccent);
      case CloudType.baidu:
        return (Icons.cloud_done_outlined, Colors.blueAccent);
      case CloudType.naver:
        return (Icons.cloud_queue_rounded, Colors.greenAccent);
      case CloudType.mega:
        return (Icons.lock_outline_rounded, Colors.redAccent);
    }
  }

  Widget _buildStorageLargeGrid(
    BuildContext context,
    List<CloudAccount> accounts,
    AccountManager accountMgr,
    double width,
  ) {
    final count = (width / 160).floor().clamp(2, 6);
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: count,
        mainAxisExtent: 130,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: accounts.length,
      itemBuilder: (context, index) {
        final acc = accounts[index];
        final (icon, color) = _getAccountIconAndColor(acc.type);
        final isLocal = acc.type == CloudType.local;

        return InkWell(
          onTap: () => _openStorage(context, acc, accountMgr),
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF1B202B),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white10),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: color.withAlpha(25),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: color, size: 28),
                ),
                const SizedBox(height: 8),
                Text(
                  acc.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                Text(
                  isLocal ? '로컬 디스크' : acc.email,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white38, fontSize: 10),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildStorageSmallGrid(
    BuildContext context,
    List<CloudAccount> accounts,
    AccountManager accountMgr,
    double width,
  ) {
    final count = (width / 200).floor().clamp(1, 4);
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: count,
        mainAxisExtent: 60,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: accounts.length,
      itemBuilder: (context, index) {
        final acc = accounts[index];
        final (icon, color) = _getAccountIconAndColor(acc.type);

        return InkWell(
          onTap: () => _openStorage(context, acc, accountMgr),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF1B202B),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white10),
            ),
            child: Row(
              children: [
                Icon(icon, color: color, size: 24),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        acc.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                      ),
                      Text(
                        acc.email.isNotEmpty ? acc.email : acc.type.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white38, fontSize: 10),
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

  Widget _buildStorageList(
    BuildContext context,
    List<CloudAccount> accounts,
    AccountManager accountMgr,
  ) {
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: accounts.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final acc = accounts[index];
        final (icon, color) = _getAccountIconAndColor(acc.type);
        final isLocal = acc.type == CloudType.local;

        return ListTile(
          tileColor: const Color(0xFF1B202B),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: Colors.white10),
          ),
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withAlpha(30),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          title: Text(acc.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          subtitle: Text(
            isLocal ? '로컬 스토리지' : acc.email,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white38, fontSize: 11),
          ),
          trailing: isLocal
              ? const Icon(Icons.arrow_forward_ios, size: 14, color: Colors.white24)
              : IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.delete_outline, size: 18, color: Colors.white38),
                  tooltip: '연결 해제',
                  onPressed: () => _confirmDeleteAccount(context, acc, accountMgr),
                ),
          onTap: () => _openStorage(context, acc, accountMgr),
        );
      },
    );
  }

  // 화면 폭 100% 꽉 채우는 반응형 저장소 테이블 뷰
  Widget _buildStorageDetailsTable(
    BuildContext context,
    List<CloudAccount> accounts,
    AccountManager accountMgr,
    double maxWidth,
  ) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF1B202B),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              color: Colors.white.withAlpha(12),
              child: const Row(
                children: [
                  Expanded(
                    flex: 4,
                    child: Text('스토리지명', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white70, fontSize: 12)),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text('서비스 종류', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white70, fontSize: 12)),
                  ),
                  Expanded(
                    flex: 4,
                    child: Text('계정 / 식별자', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white70, fontSize: 12)),
                  ),
                  SizedBox(
                    width: 32,
                    child: Center(
                      child: Text('동작', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white70, fontSize: 11)),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Colors.white12),
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: accounts.length,
              separatorBuilder: (_, _) => const Divider(height: 1, color: Colors.white10),
              itemBuilder: (context, index) {
                final acc = accounts[index];
                final (icon, color) = _getAccountIconAndColor(acc.type);
                final isLocal = acc.type == CloudType.local;

                return InkWell(
                  onTap: () => _openStorage(context, acc, accountMgr),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 4,
                          child: Row(
                            children: [
                              Icon(icon, color: color, size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  acc.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          flex: 3,
                          child: Text(
                            acc.type.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white60, fontSize: 11),
                          ),
                        ),
                        Expanded(
                          flex: 4,
                          child: Text(
                            isLocal ? '내 컴퓨터' : acc.email,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white38, fontSize: 11),
                          ),
                        ),
                        SizedBox(
                          width: 32,
                          child: isLocal
                              ? const SizedBox.shrink()
                              : IconButton(
                                  padding: EdgeInsets.zero,
                                  visualDensity: VisualDensity.compact,
                                  icon: const Icon(Icons.delete_outline, size: 16, color: Colors.white38),
                                  onPressed: () => _confirmDeleteAccount(context, acc, accountMgr),
                                ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDeleteAccount(BuildContext context, CloudAccount account, AccountManager mgr) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('클라우드 연결 해제'),
        content: Text('\'${account.name}\' 계정 연결을 해제하시겠습니까?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
          ElevatedButton(
            onPressed: () {
              mgr.removeAccount(account.id);
              Navigator.pop(ctx);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('해제', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}
