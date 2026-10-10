import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import '../../models/cloud_account.dart';
import '../../models/folder_shortcut.dart';
import '../../models/media_item.dart';
import '../../services/cloud_service_interface.dart';
import '../../services/folder_shortcut_manager.dart';
import '../../services/local_disk_service.dart';
import '../../utils/permission_utils.dart';
import 'comic_viewer_screen.dart';

enum BrowserViewMode {
  largeIcons('큰 아이콘', Icons.grid_view_rounded),
  smallIcons('작은 아이콘', Icons.view_comfy_alt_outlined),
  list('목록', Icons.format_list_bulleted_rounded),
  details('자세히', Icons.table_rows_outlined);

  final String label;
  final IconData icon;
  const BrowserViewMode(this.label, this.icon);
}

class BrowserScreen extends StatefulWidget {
  final CloudAccount account;
  final CloudService service;
  final String? initialFolderId;
  final String? initialFolderName;

  const BrowserScreen({
    super.key,
    required this.account,
    required this.service,
    this.initialFolderId,
    this.initialFolderName,
  });

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  bool _isLoading = true;
  String? _errorMessage;
  List<MediaItem> _allItems = [];
  List<MediaItem> _filteredItems = [];

  late final List<MapEntry<String?, String>> _folderStack;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _breadcrumbScrollController = ScrollController();

  String get _currentFolderPath => _folderStack.map((e) => e.value).join(' > ');

  static const String _prefViewModeKey = 'comic_browser_view_mode';
  BrowserViewMode _viewMode = BrowserViewMode.details;

  @override
  void initState() {
    super.initState();
    _loadViewMode();
    _folderStack = [
      MapEntry(null, widget.account.type == CloudType.local ? '내 PC' : '홈'),
      if (widget.initialFolderId != null)
        MapEntry(widget.initialFolderId, widget.initialFolderName ?? '폴더'),
    ];
    _loadFolder();
  }

  Future<void> _loadViewMode() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefViewModeKey);
    if (saved != null) {
      final mode = BrowserViewMode.values.firstWhere(
        (m) => m.name == saved,
        orElse: () => BrowserViewMode.details,
      );
      if (mounted) {
        setState(() => _viewMode = mode);
      }
    }
  }

  Future<void> _changeViewMode(BrowserViewMode mode) async {
    setState(() => _viewMode = mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefViewModeKey, mode.name);
  }

  @override
  void dispose() {
    _breadcrumbScrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _scrollToCurrentFolder() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_breadcrumbScrollController.hasClients) {
        _breadcrumbScrollController.animateTo(
          _breadcrumbScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _loadFolder() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final currentFolderId = _folderStack.last.key;
      final items = await widget.service.listItems(folderId: currentFolderId);
      if (mounted) {
        setState(() {
          _allItems = items;
          _applyFilter();
          _isLoading = false;
        });
        _scrollToCurrentFolder();
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

  void _applyFilter() {
    if (_searchQuery.trim().isEmpty) {
      _filteredItems = List.from(_allItems);
    } else {
      final q = _searchQuery.toLowerCase();
      _filteredItems = _allItems.where((item) => item.name.toLowerCase().contains(q)).toList();
    }
  }

  void _navigateToFolder(MediaItem folder) {
    if (folder.id == '__ACTION_ADD_STORAGE__') {
      _pickAndAddCustomStorage();
      return;
    }
    _folderStack.add(MapEntry(folder.id, folder.name));
    _searchController.clear();
    _searchQuery = '';
    _loadFolder();
  }

  Future<void> _pickAndAddCustomStorage() async {
    if (Platform.isAndroid) {
      final hasPermission = await PermissionUtils.ensureStoragePermission();
      if (!hasPermission && mounted) {
        await PermissionUtils.showPermissionGuideDialog(context);
      }
    }

    try {
      final selectedDirectory = await FilePicker.getDirectoryPath(
        dialogTitle: '추가할 만화책 폴더 / SD 카드 저장소 선택',
      );

      if (selectedDirectory != null && selectedDirectory.isNotEmpty) {
        await LocalDiskService.addCustomStoragePath(selectedDirectory);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('저장소 폴더가 등록되었습니다: $selectedDirectory')),
          );
          _loadFolder();
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('폴더 선택 실패: $e')),
        );
      }
    }
  }

  void _navigateToIndex(int index) {
    if (index < _folderStack.length - 1) {
      setState(() {
        _folderStack.removeRange(index + 1, _folderStack.length);
        _searchController.clear();
        _searchQuery = '';
      });
      _loadFolder();
    }
  }

  bool _navigateBack() {
    if (_folderStack.length > 1) {
      setState(() {
        _folderStack.removeLast();
        _searchController.clear();
        _searchQuery = '';
      });
      _loadFolder();
      return false;
    }
    return true;
  }

  void _openComicViewer(MediaItem item) {
    if (!item.isViewable) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('만화책 압축 파일(ZIP/CBZ) 또는 이미지 파일만 열 수 있습니다.')),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ComicViewerScreen(
          item: item,
          service: widget.service,
          folderSiblings: _allItems,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentFolderName = _folderStack.last.value;

    return PopScope(
      canPop: _folderStack.length <= 1,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _navigateBack();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(currentFolderName, style: const TextStyle(fontWeight: FontWeight.bold)),
          actions: [
            // 윈도우 탐색기 스타일 보기 옵션 드롭다운 메뉴 (큰 아이콘 / 작은 아이콘 / 목록 / 자세히)
            PopupMenuButton<BrowserViewMode>(
              tooltip: '보기 옵션 (${_viewMode.label})',
              onSelected: _changeViewMode,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                margin: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(_viewMode.icon, size: 18, color: Colors.blueAccent),
                    const SizedBox(width: 6),
                    Text(
                      _viewMode.label,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(width: 2),
                    const Icon(Icons.arrow_drop_down, size: 18, color: Colors.white70),
                  ],
                ),
              ),
              itemBuilder: (context) => BrowserViewMode.values.map((mode) {
                final isSelected = mode == _viewMode;
                return PopupMenuItem<BrowserViewMode>(
                  value: mode,
                  child: Row(
                    children: [
                      Icon(
                        mode.icon,
                        size: 20,
                        color: isSelected ? Colors.blueAccent : Colors.white70,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        mode.label,
                        style: TextStyle(
                          color: isSelected ? Colors.blueAccent : Colors.white,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
            // 홈 바로가기 추가 버튼
            if (_folderStack.length > 1)
              Consumer<FolderShortcutManager>(
                builder: (context, shortcutMgr, _) {
                  final currentFolderId = _folderStack.last.key;
                  final isBookmarked = currentFolderId != null &&
                      shortcutMgr.isFolderShortcut(widget.account.id, currentFolderId);

                  return IconButton(
                    icon: Icon(
                      isBookmarked ? Icons.bookmark : Icons.bookmark_add_outlined,
                      color: isBookmarked ? Colors.amber : Colors.white70,
                    ),
                    tooltip: isBookmarked ? '홈 바로가기 해제' : '홈 바로가기에 추가',
                    onPressed: () async {
                      if (currentFolderId == null) return;
                      if (isBookmarked) {
                        await shortcutMgr.removeShortcutByFolder(widget.account.id, currentFolderId);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('\'$currentFolderName\' 바로가기가 해제되었습니다.')),
                          );
                        }
                      } else {
                        final shortcut = FolderShortcut(
                          id: '${widget.account.id}_$currentFolderId',
                          accountId: widget.account.id,
                          accountName: widget.account.name,
                          cloudType: widget.account.type,
                          folderId: currentFolderId,
                          folderName: currentFolderName,
                          folderPath: _currentFolderPath,
                          createdAt: DateTime.now(),
                        );
                        await shortcutMgr.addShortcut(shortcut);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('\'$currentFolderName\' 홈 바로가기에 추가되었습니다.')),
                          );
                        }
                      }
                    },
                  );
                },
              ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '새로고침',
              onPressed: _loadFolder,
            ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(96),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildBreadcrumbBar(),
                _buildSearchBar(),
              ],
            ),
          ),
        ),
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBreadcrumbBar() {
    return Container(
      height: 44,
      width: double.infinity,
      color: Colors.black26,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          // 1. 앱의 첫 시작 화면(HomeScreen)으로 즉시 돌아가는 홈 버튼
          InkWell(
            onTap: () => Navigator.of(context).pop(),
            borderRadius: BorderRadius.circular(6),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.home, size: 18, color: Colors.blueAccent),
                  SizedBox(width: 4),
                  Text(
                    '홈',
                    style: TextStyle(color: Colors.blueAccent, fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ),
          const Icon(Icons.chevron_right, size: 18, color: Colors.white38),

          // 2. 현재 계정 및 폴더 탐색 경로 목록
          Expanded(
            child: ListView.separated(
              controller: _breadcrumbScrollController,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              itemCount: _folderStack.length,
              separatorBuilder: (_, _) => const Icon(Icons.chevron_right, size: 18, color: Colors.white38),
              itemBuilder: (context, index) {
                final isLast = index == _folderStack.length - 1;
                final title = _folderStack[index].value;

                return Center(
                  child: InkWell(
                    onTap: isLast ? null : () => _navigateToIndex(index),
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      child: Text(
                        title,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: isLast ? FontWeight.bold : FontWeight.normal,
                          color: isLast ? Colors.white : Colors.white70,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: TextField(
        controller: _searchController,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          hintText: '현재 폴더 내 만화책/이미지 검색...',
          hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
          prefixIcon: const Icon(Icons.search, size: 20, color: Colors.white54),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 18, color: Colors.white54),
                  onPressed: () {
                    _searchController.clear();
                    setState(() {
                      _searchQuery = '';
                      _applyFilter();
                    });
                  },
                )
              : null,
          contentPadding: EdgeInsets.zero,
          filled: true,
          fillColor: const Color(0xFF1B202B),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
        ),
        onChanged: (val) {
          setState(() {
            _searchQuery = val;
            _applyFilter();
          });
        },
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(color: Colors.blueAccent));
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
              Text(_errorMessage!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: _loadFolder,
                icon: const Icon(Icons.refresh),
                label: const Text('다시 시도'),
              ),
            ],
          ),
        ),
      );
    }

    if (_filteredItems.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.folder_open, size: 64, color: Colors.grey.withAlpha(128)),
              const SizedBox(height: 16),
              const Text('만화책(ZIP/CBZ) 또는 이미지 파일이 없습니다.', style: TextStyle(color: Colors.grey, fontSize: 15)),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadFolder,
      child: LayoutBuilder(
        builder: (context, constraints) {
          switch (_viewMode) {
            case BrowserViewMode.largeIcons:
              return _buildLargeIconsView(context, constraints.maxWidth);
            case BrowserViewMode.smallIcons:
              return _buildSmallIconsView(context, constraints.maxWidth);
            case BrowserViewMode.list:
              return _buildListView(context);
            case BrowserViewMode.details:
              return _buildDetailsView(context);
          }
        },
      ),
    );
  }

  // 1. 큰 아이콘 보기 (대형 카드 그리드)
  Widget _buildLargeIconsView(BuildContext context, double maxWidth) {
    final cols = math.max(2, (maxWidth / 160).floor());
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        childAspectRatio: 0.78,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: _filteredItems.length,
      itemBuilder: (context, index) {
        final item = _filteredItems[index];

        if (item.isFolder) {
          return InkWell(
            onTap: () => _navigateToFolder(item),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF1B202B),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.amber.withAlpha(40)),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.folder, size: 54, color: Colors.amber),
                  const SizedBox(height: 10),
                  Text(
                    item.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  const Text('폴더', style: TextStyle(color: Colors.white38, fontSize: 10.5)),
                ],
              ),
            ),
          );
        }

        final isArchive = item.isComicArchive;
        final iconColor = isArchive ? Colors.blueAccent : Colors.tealAccent;

        return InkWell(
          onTap: () => _openComicViewer(item),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF1B202B),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white10),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 58,
                  height: 58,
                  decoration: BoxDecoration(
                    color: iconColor.withAlpha(25),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    isArchive ? Icons.auto_stories : Icons.image,
                    size: 34,
                    color: iconColor,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  item.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, height: 1.25),
                ),
                const SizedBox(height: 4),
                if (item.formattedSize.isNotEmpty)
                  Text(
                    item.formattedSize,
                    style: const TextStyle(color: Colors.white38, fontSize: 10.5),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  // 2. 작은 아이콘 보기 (컴팩트 그리드)
  Widget _buildSmallIconsView(BuildContext context, double maxWidth) {
    final cols = math.max(3, (maxWidth / 105).floor());
    return GridView.builder(
      padding: const EdgeInsets.all(10),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        childAspectRatio: 0.88,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: _filteredItems.length,
      itemBuilder: (context, index) {
        final item = _filteredItems[index];

        if (item.isFolder) {
          return InkWell(
            onTap: () => _navigateToFolder(item),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFF1B202B),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white10),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.folder, size: 36, color: Colors.amber),
                  const SizedBox(height: 6),
                  Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
          );
        }

        final isArchive = item.isComicArchive;
        final iconColor = isArchive ? Colors.blueAccent : Colors.tealAccent;

        return InkWell(
          onTap: () => _openComicViewer(item),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: const Color(0xFF1B202B),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white10),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  isArchive ? Icons.auto_stories : Icons.image,
                  size: 32,
                  color: iconColor,
                ),
                const SizedBox(height: 6),
                Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w500),
                ),
                if (item.formattedSize.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    item.formattedSize,
                    style: const TextStyle(color: Colors.white38, fontSize: 9.5),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  // 3. 목록 보기 (심플 1줄 리스트)
  Widget _buildListView(BuildContext context) {
    return ListView.builder(
      itemCount: _filteredItems.length,
      itemBuilder: (context, index) {
        final item = _filteredItems[index];

        if (item.isFolder) {
          return ListTile(
            dense: true,
            visualDensity: const VisualDensity(vertical: -1),
            leading: const Icon(Icons.folder, color: Colors.amber, size: 26),
            title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5)),
            trailing: const Icon(Icons.chevron_right, size: 18, color: Colors.white24),
            onTap: () => _navigateToFolder(item),
          );
        }

        final isArchive = item.isComicArchive;
        final iconColor = isArchive ? Colors.blueAccent : Colors.tealAccent;

        return ListTile(
          dense: true,
          visualDensity: const VisualDensity(vertical: -1),
          leading: Icon(isArchive ? Icons.auto_stories : Icons.image, color: iconColor, size: 24),
          title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5)),
          trailing: Text(
            item.formattedSize,
            style: const TextStyle(color: Colors.white38, fontSize: 11),
          ),
          onTap: () => _openComicViewer(item),
        );
      },
    );
  }

  // 4. 자세히 보기 (상세 정보 포함 리스트)
  Widget _buildDetailsView(BuildContext context) {
    return ListView.builder(
      itemCount: _filteredItems.length,
      itemBuilder: (context, index) {
        final item = _filteredItems[index];

        if (item.isFolder) {
          return ListTile(
            leading: const Icon(Icons.folder, color: Colors.amber, size: 36),
            title: Text(item.name, style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14)),
            subtitle: const Text('폴더', style: TextStyle(color: Colors.grey, fontSize: 12)),
            trailing: const Icon(Icons.chevron_right, size: 20, color: Colors.white24),
            onTap: () => _navigateToFolder(item),
          );
        }

        final isArchive = item.isComicArchive;
        final iconColor = isArchive ? Colors.blueAccent : Colors.tealAccent;
        final icon = isArchive ? Icons.auto_stories : Icons.image;

        return ListTile(
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: iconColor.withAlpha(30),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: iconColor, size: 22),
          ),
          title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
          subtitle: Row(
            children: [
              if (item.formattedSize.isNotEmpty) ...[
                Text(item.formattedSize, style: const TextStyle(color: Colors.grey, fontSize: 12)),
                const SizedBox(width: 8),
              ],
              if (item.modifiedTime != null)
                Text(
                  DateFormat('yyyy-MM-dd HH:mm').format(item.modifiedTime!),
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
            ],
          ),
          trailing: const Icon(Icons.play_circle_outline, color: Colors.blueAccent, size: 24),
          onTap: () => _openComicViewer(item),
        );
      },
    );
  }
}
