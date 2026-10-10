import 'dart:io';
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
  details('자세히 보기', Icons.view_list),
  largeIcons('큰 아이콘 (그리드)', Icons.grid_view);

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
            // 뷰 모드 변경
            PopupMenuButton<BrowserViewMode>(
              icon: Icon(_viewMode.icon),
              tooltip: '보기 모드 변경',
              onSelected: _changeViewMode,
              itemBuilder: (context) => BrowserViewMode.values.map((mode) {
                final isSelected = mode == _viewMode;
                return PopupMenuItem(
                  value: mode,
                  child: Row(
                    children: [
                      Icon(mode.icon, size: 20, color: isSelected ? Colors.blueAccent : Colors.white70),
                      const SizedBox(width: 12),
                      Text(mode.label, style: TextStyle(color: isSelected ? Colors.blueAccent : Colors.white)),
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
      child: ListView.separated(
        controller: _breadcrumbScrollController,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
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
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: isLast ? FontWeight.bold : FontWeight.normal,
                    color: isLast ? Colors.blueAccent : Colors.white70,
                  ),
                ),
              ),
            ),
          );
        },
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
      child: _viewMode == BrowserViewMode.largeIcons
          ? _buildGridView(context)
          : _buildListView(context),
    );
  }

  Widget _buildListView(BuildContext context) {
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
                  DateFormat('yyyy-MM-dd').format(item.modifiedTime!),
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

  Widget _buildGridView(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 0.75,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: _filteredItems.length,
      itemBuilder: (context, index) {
        final item = _filteredItems[index];

        if (item.isFolder) {
          return InkWell(
            onTap: () => _navigateToFolder(item),
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF1E212B),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white10),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.folder, size: 48, color: Colors.amber),
                  const SizedBox(height: 8),
                  Text(
                    item.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          );
        }

        final isArchive = item.isComicArchive;

        return InkWell(
          onTap: () => _openComicViewer(item),
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF1E212B),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white10),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  isArchive ? Icons.auto_stories : Icons.image,
                  size: 44,
                  color: isArchive ? Colors.blueAccent : Colors.tealAccent,
                ),
                const SizedBox(height: 8),
                Text(
                  item.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 4),
                if (item.formattedSize.isNotEmpty)
                  Text(
                    item.formattedSize,
                    style: const TextStyle(color: Colors.white38, fontSize: 10),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
