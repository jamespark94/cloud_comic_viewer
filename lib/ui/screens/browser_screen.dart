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
import '../../services/account_manager.dart';
import '../../services/cloud_history_sync_service.dart';
import '../../services/cloud_service_interface.dart';
import '../../services/folder_shortcut_manager.dart';
import '../../services/local_disk_service.dart';
import '../../services/reading_history_service.dart';
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

enum ConflictResolution {
  rename,
  overwrite,
  cancel,
}

class ConflictResolutionResult {
  final ConflictResolution resolution;
  final String? newName;
  const ConflictResolutionResult(this.resolution, [this.newName]);
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

  MediaItem? _clipboardItem;
  bool _isCutMode = false;
  String? _clipboardSourceFolderId;

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
    ).then((_) {
      if (mounted) {
        final accountMgr = context.read<AccountManager>();
        CloudHistorySyncService.instance.syncHistories(accountMgr, silent: true);
      }
    });
  }

  Future<void> _toggleFolderShortcut(
    MediaItem item,
    FolderShortcutManager shortcutMgr,
    bool isBookmarked,
  ) async {
    if (isBookmarked) {
      await shortcutMgr.removeShortcutByFolder(widget.account.id, item.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('\'${item.name}\' 바로가기가 해제되었습니다.')),
        );
      }
    } else {
      final shortcut = FolderShortcut(
        id: '${widget.account.id}_${item.id}',
        accountId: widget.account.id,
        accountName: widget.account.name,
        cloudType: widget.account.type,
        folderId: item.id,
        folderName: item.name,
        folderPath: _currentFolderPath,
        createdAt: DateTime.now(),
      );
      await shortcutMgr.addShortcut(shortcut);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('\'${item.name}\' 홈 바로가기에 추가되었습니다.')),
        );
      }
    }
  }

  Future<void> _promptNewFolder() async {
    final textController = TextEditingController();
    final folderName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E2433),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Row(
          children: const [
            Icon(Icons.create_new_folder, color: Colors.blueAccent, size: 24),
            SizedBox(width: 8),
            Text('새 폴더 생성', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        content: TextField(
          controller: textController,
          autofocus: true,
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            labelText: '폴더 이름',
            hintText: '새 폴더명을 입력하세요',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onSubmitted: (val) {
            final trimmed = val.trim();
            if (trimmed.isNotEmpty) {
              Navigator.pop(ctx, trimmed);
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('취소', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
            onPressed: () {
              final val = textController.text.trim();
              if (val.isNotEmpty) {
                Navigator.pop(ctx, val);
              } else {
                Navigator.pop(ctx, null);
              }
            },
            child: const Text('생성', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (folderName != null && folderName.isNotEmpty) {
      setState(() => _isLoading = true);
      final parentId = _folderStack.last.key;
      final ok = await widget.service.createFolder(folderName, parentFolderId: parentId);
      if (mounted) {
        if (ok) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('\'$folderName\' 폴더가 생성되었습니다.')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('새 폴더 생성에 실패했습니다.')),
          );
        }
        _loadFolder();
      }
    }
  }

  Future<void> _promptRename(MediaItem item) async {
    final textController = TextEditingController(text: item.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E2433),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Row(
          children: [
            Icon(item.isFolder ? Icons.folder : Icons.edit, color: Colors.amber, size: 22),
            const SizedBox(width: 8),
            const Text('이름 변경', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        content: TextField(
          controller: textController,
          autofocus: true,
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            labelText: '새 이름',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onSubmitted: (val) {
            final trimmed = val.trim();
            if (trimmed.isNotEmpty && trimmed != item.name) {
              Navigator.pop(ctx, trimmed);
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('취소', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
            onPressed: () {
              final val = textController.text.trim();
              if (val.isNotEmpty && val != item.name) {
                Navigator.pop(ctx, val);
              } else {
                Navigator.pop(ctx, null);
              }
            },
            child: const Text('변경', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (newName != null && newName.isNotEmpty && newName != item.name) {
      setState(() => _isLoading = true);
      final ok = await widget.service.renameItem(item, newName);
      if (mounted) {
        if (ok) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('\'$newName\'(으)로 이름이 변경되었습니다.')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('이름 변경에 실패했습니다.')),
          );
        }
        _loadFolder();
      }
    }
  }

  Future<void> _confirmDelete(MediaItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E2433),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Row(
          children: const [
            Icon(Icons.delete_forever, color: Colors.redAccent, size: 24),
            SizedBox(width: 8),
            Text('삭제 확인', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text(
          '\'${item.name}\'${item.isFolder ? ' 폴더와 내부 모든 파일' : ''}을(를) 정말 삭제하시겠습니까?\n\n이 작업은 되돌릴 수 없습니다.',
          style: const TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      setState(() => _isLoading = true);
      final ok = await widget.service.deleteItem(item);
      if (mounted) {
        if (ok) {
          if (item.isViewable) {
            await ReadingHistoryService.instance.removeHistory(item.id, title: item.name);
            if (mounted) {
              final accountMgr = context.read<AccountManager>();
              CloudHistorySyncService.instance.syncHistories(accountMgr, silent: true);
            }
          } else if (item.isFolder && mounted) {
            final shortcutMgr = context.read<FolderShortcutManager>();
            if (shortcutMgr.isFolderShortcut(widget.account.id, item.id)) {
              await shortcutMgr.removeShortcutByFolder(widget.account.id, item.id);
            }
          }
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('\'${item.name}\'이(가) 삭제되었습니다.')),
          );
        } else {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('삭제에 실패했습니다.')),
          );
        }
        _loadFolder();
      }
    }
  }

  String _generateCopyName({
    required String originalName,
    required bool isFolder,
    required Iterable<String> existingNames,
    bool isSameFolder = true,
  }) {
    String baseName;
    String extension;

    if (!isFolder && originalName.contains('.') && originalName.lastIndexOf('.') > 0) {
      final dotIndex = originalName.lastIndexOf('.');
      baseName = originalName.substring(0, dotIndex);
      extension = originalName.substring(dotIndex);
    } else {
      baseName = originalName;
      extension = '';
    }

    if (isSameFolder) {
      String candidate = '$baseName - 복사본$extension';
      if (!existingNames.any((n) => n.toLowerCase() == candidate.toLowerCase())) {
        return candidate;
      }
      int count = 2;
      while (true) {
        candidate = '$baseName - 복사본 ($count)$extension';
        if (!existingNames.any((n) => n.toLowerCase() == candidate.toLowerCase())) {
          return candidate;
        }
        count++;
      }
    } else {
      int count = 1;
      while (true) {
        final candidate = '$baseName ($count)$extension';
        if (!existingNames.any((n) => n.toLowerCase() == candidate.toLowerCase())) {
          return candidate;
        }
        count++;
      }
    }
  }

  Future<ConflictResolutionResult?> _showConflictDialog({
    required MediaItem item,
    required bool isCutMode,
    required String suggestedName,
  }) async {
    final nameController = TextEditingController(text: suggestedName);
    return showDialog<ConflictResolutionResult>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E2433),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Row(
          children: const [
            Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 24),
            SizedBox(width: 8),
            Text('이름 중복 확인', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '대상 폴더에 이미 동일한 이름의 \'${item.name}\' ${item.isFolder ? '폴더' : '파일'}이(가) 존재합니다.',
              style: const TextStyle(fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 14),
            const Text(
              '새 이름으로 변경하여 둘 다 유지:',
              style: TextStyle(fontSize: 12, color: Colors.white70),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: nameController,
              autofocus: false,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, const ConflictResolutionResult(ConflictResolution.cancel)),
            child: const Text('취소', style: TextStyle(color: Colors.white60)),
          ),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.redAccent,
              side: const BorderSide(color: Colors.redAccent),
            ),
            onPressed: () => Navigator.pop(ctx, const ConflictResolutionResult(ConflictResolution.overwrite)),
            child: const Text('덮어쓰기'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
            onPressed: () {
              final customName = nameController.text.trim();
              Navigator.pop(
                ctx,
                ConflictResolutionResult(
                  ConflictResolution.rename,
                  customName.isNotEmpty ? customName : suggestedName,
                ),
              );
            },
            child: Text(
              isCutMode ? '이름 변경 후 이동' : '이름 변경 후 복사',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _executePasteOrMove() async {
    if (_clipboardItem == null) return;
    final item = _clipboardItem!;
    final targetFolderId = _folderStack.last.key;

    if (widget.account.type == CloudType.local && _folderStack.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('드라이브 또는 대상 폴더 내부로 먼저 이동한 후 붙여넣어 주세요.')),
      );
      return;
    }

    if (item.id == targetFolderId) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('동일한 폴더로 이동하거나 복사할 수 없습니다.')),
      );
      return;
    }

    if (item.isFolder && targetFolderId != null && targetFolderId.startsWith(item.id)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('상위 폴더를 하위 폴더로 이동하거나 복사할 수 없습니다.')),
      );
      return;
    }

    final isSameFolder = _clipboardSourceFolderId == targetFolderId;

    if (_isCutMode && isSameFolder) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('이미 동일한 폴더에 위치해 있습니다.')),
      );
      return;
    }

    final existingNames = _allItems.map((e) => e.name).toList();
    final hasNameConflict = existingNames.any((n) => n.toLowerCase() == item.name.toLowerCase());

    String? finalName;
    bool overwrite = false;

    if (!_isCutMode && isSameFolder) {
      // 1. 동일한 폴더 내 복사: 자동으로 "파일명 - 복사본" 부여
      finalName = _generateCopyName(
        originalName: item.name,
        isFolder: item.isFolder,
        existingNames: existingNames,
        isSameFolder: true,
      );
    } else if (hasNameConflict) {
      // 2. 다른 폴더에 동일 이름이 이미 존재하는 경우: 충돌 해결 다이얼로그
      final suggestedName = _generateCopyName(
        originalName: item.name,
        isFolder: item.isFolder,
        existingNames: existingNames,
        isSameFolder: false,
      );
      final result = await _showConflictDialog(
        item: item,
        isCutMode: _isCutMode,
        suggestedName: suggestedName,
      );

      if (result == null || result.resolution == ConflictResolution.cancel) {
        return;
      }

      if (result.resolution == ConflictResolution.overwrite) {
        overwrite = true;
        finalName = item.name;
      } else if (result.resolution == ConflictResolution.rename) {
        finalName = result.newName ?? suggestedName;
      }
    }

    setState(() {
      _isLoading = true;
    });

    bool success = false;
    try {
      if (_isCutMode) {
        success = await widget.service.moveItem(
          item,
          targetFolderId ?? '',
          newName: finalName,
          overwrite: overwrite,
        );
      } else {
        success = await widget.service.copyItem(
          item,
          targetFolderId ?? '',
          newName: finalName,
          overwrite: overwrite,
        );
      }
    } catch (e) {
      debugPrint('[BrowserScreen] 붙여넣기/이동 오류: $e');
    }

    if (mounted) {
      final opText = _isCutMode ? '이동' : '복사';
      if (success) {
        final displayName = finalName ?? item.name;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('\'$displayName\' $opText이(가) 완료되었습니다.')),
        );
        setState(() {
          _clipboardItem = null;
          _clipboardSourceFolderId = null;
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$opText에 실패했습니다.')),
        );
      }
      _loadFolder();
    }
  }

  void _showItemOperationsMenu(BuildContext context, MediaItem item) {
    final shortcutMgr = context.read<FolderShortcutManager>();
    final isBookmarked = item.isFolder && shortcutMgr.isFolderShortcut(widget.account.id, item.id);

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF191E2A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                children: [
                  Icon(
                    item.isFolder
                        ? Icons.folder
                        : (item.isComicArchive
                            ? Icons.auto_stories
                            : (item.isImage ? Icons.image : Icons.insert_drive_file)),
                    color: item.isFolder
                        ? Colors.amber
                        : (item.isComicArchive ? Colors.blueAccent : Colors.tealAccent),
                    size: 24,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      item.name,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white12, height: 12),
            if (item.isViewable)
              ListTile(
                dense: true,
                leading: const Icon(Icons.menu_book_rounded, color: Colors.blueAccent),
                title: const Text('만화 열기'),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _openComicViewer(item);
                },
              ),
            if (item.isFolder)
              ListTile(
                dense: true,
                leading: Icon(
                  isBookmarked ? Icons.bookmark_remove : Icons.bookmark_add_outlined,
                  color: Colors.amber,
                ),
                title: Text(isBookmarked ? '첫 화면 바로가기 해제' : '첫 화면 바로가기에 추가'),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _toggleFolderShortcut(item, shortcutMgr, isBookmarked);
                },
              ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.copy_outlined, color: Colors.lightBlueAccent),
              title: const Text('복사'),
              onTap: () {
                Navigator.pop(sheetCtx);
                setState(() {
                  _clipboardItem = item;
                  _isCutMode = false;
                  _clipboardSourceFolderId = _folderStack.last.key;
                });
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('\'${item.name}\' 복사 대기 중입니다. 대상 폴더에서 [붙여넣기]를 누르세요.'),
                    duration: const Duration(seconds: 3),
                  ),
                );
              },
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.drive_file_move_outlined, color: Colors.orangeAccent),
              title: const Text('잘라내기 (이동)'),
              onTap: () {
                Navigator.pop(sheetCtx);
                setState(() {
                  _clipboardItem = item;
                  _isCutMode = true;
                  _clipboardSourceFolderId = _folderStack.last.key;
                });
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('\'${item.name}\' 이동 대기 중입니다. 대상 폴더에서 [여기로 이동]을 누르세요.'),
                    duration: const Duration(seconds: 3),
                  ),
                );
              },
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.drive_file_rename_outline, color: Colors.tealAccent),
              title: const Text('이름 변경'),
              onTap: () {
                Navigator.pop(sheetCtx);
                _promptRename(item);
              },
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
              title: const Text('삭제', style: TextStyle(color: Colors.redAccent)),
              onTap: () {
                Navigator.pop(sheetCtx);
                _confirmDelete(item);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildClipboardBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1E2433),
        border: const Border(top: BorderSide(color: Colors.white24, width: 0.8)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(120),
            blurRadius: 10,
            offset: const Offset(0, -3),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Icon(
              _isCutMode ? Icons.drive_file_move : Icons.copy_all,
              color: Colors.amber,
              size: 24,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _isCutMode ? '이동 대기 중' : '복사 대기 중',
                    style: const TextStyle(fontSize: 11, color: Colors.amber, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    _clipboardItem?.name ?? '',
                    style: const TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blueAccent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              icon: Icon(_isCutMode ? Icons.drive_file_move_outlined : Icons.content_paste, size: 16),
              label: Text(
                _isCutMode ? '여기로 이동' : '여기에 붙여넣기',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              ),
              onPressed: _executePasteOrMove,
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white60, size: 20),
              tooltip: '취소',
              onPressed: () {
                setState(() {
                  _clipboardItem = null;
                  _clipboardSourceFolderId = null;
                });
              },
            ),
          ],
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
            // 새 폴더 생성 버튼 (로컬 최상단 저장소 목록일 때는 제외)
            if (!(widget.account.type == CloudType.local && _folderStack.length <= 1))
              IconButton(
                icon: const Icon(Icons.create_new_folder_outlined),
                tooltip: '새 폴더 생성',
                onPressed: _promptNewFolder,
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
        bottomNavigationBar: _clipboardItem != null ? _buildClipboardBar() : null,
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
          final isShortcut = item.id != '__ACTION_ADD_STORAGE__' &&
              context.watch<FolderShortcutManager>().isFolderShortcut(widget.account.id, item.id);
          return InkWell(
            onTap: () => _navigateToFolder(item),
            onLongPress: item.id == '__ACTION_ADD_STORAGE__' ? null : () => _showItemOperationsMenu(context, item),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF1B202B),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.amber.withAlpha(40)),
              ),
              child: Stack(
                children: [
                  Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.folder, size: 52, color: Colors.amber),
                        const SizedBox(height: 8),
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
                  if (item.id != '__ACTION_ADD_STORAGE__')
                    Positioned(
                      top: 0,
                      right: 0,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Consumer<FolderShortcutManager>(
                            builder: (context, shortcutMgr, _) => InkWell(
                              onTap: () => _toggleFolderShortcut(item, shortcutMgr, isShortcut),
                              borderRadius: BorderRadius.circular(12),
                              child: Padding(
                                padding: const EdgeInsets.all(4),
                                child: Icon(
                                  isShortcut ? Icons.bookmark : Icons.bookmark_add_outlined,
                                  size: 16,
                                  color: isShortcut ? Colors.amber : Colors.white38,
                                ),
                              ),
                            ),
                          ),
                          InkWell(
                            onTap: () => _showItemOperationsMenu(context, item),
                            borderRadius: BorderRadius.circular(12),
                            child: const Padding(
                              padding: EdgeInsets.all(4),
                              child: Icon(Icons.more_vert, size: 16, color: Colors.white54),
                            ),
                          ),
                        ],
                      ),
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
          onLongPress: () => _showItemOperationsMenu(context, item),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF1B202B),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white10),
            ),
            child: Stack(
              children: [
                Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 54,
                        height: 54,
                        decoration: BoxDecoration(
                          color: iconColor.withAlpha(25),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          isArchive ? Icons.auto_stories : Icons.image,
                          size: 32,
                          color: iconColor,
                        ),
                      ),
                      const SizedBox(height: 8),
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
                Positioned(
                  top: 0,
                  right: 0,
                  child: InkWell(
                    onTap: () => _showItemOperationsMenu(context, item),
                    borderRadius: BorderRadius.circular(12),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.more_vert, size: 16, color: Colors.white54),
                    ),
                  ),
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
            onLongPress: item.id == '__ACTION_ADD_STORAGE__' ? null : () => _showItemOperationsMenu(context, item),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFF1B202B),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white10),
              ),
              child: Stack(
                children: [
                  Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.folder, size: 34, color: Colors.amber),
                        const SizedBox(height: 4),
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
                  if (item.id != '__ACTION_ADD_STORAGE__')
                    Positioned(
                      top: -4,
                      right: -4,
                      child: InkWell(
                        onTap: () => _showItemOperationsMenu(context, item),
                        borderRadius: BorderRadius.circular(10),
                        child: const Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(Icons.more_vert, size: 14, color: Colors.white38),
                        ),
                      ),
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
          onLongPress: () => _showItemOperationsMenu(context, item),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: const Color(0xFF1B202B),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white10),
            ),
            child: Stack(
              children: [
                Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        isArchive ? Icons.auto_stories : Icons.image,
                        size: 30,
                        color: iconColor,
                      ),
                      const SizedBox(height: 4),
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
                Positioned(
                  top: -4,
                  right: -4,
                  child: InkWell(
                    onTap: () => _showItemOperationsMenu(context, item),
                    borderRadius: BorderRadius.circular(10),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.more_vert, size: 14, color: Colors.white38),
                    ),
                  ),
                ),
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
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (item.id != '__ACTION_ADD_STORAGE__')
                  IconButton(
                    icon: const Icon(Icons.more_vert, size: 18, color: Colors.white54),
                    tooltip: '옵션 더보기',
                    onPressed: () => _showItemOperationsMenu(context, item),
                  ),
                const Icon(Icons.chevron_right, size: 18, color: Colors.white24),
              ],
            ),
            onTap: () => _navigateToFolder(item),
            onLongPress: item.id == '__ACTION_ADD_STORAGE__' ? null : () => _showItemOperationsMenu(context, item),
          );
        }

        final isArchive = item.isComicArchive;
        final iconColor = isArchive ? Colors.blueAccent : Colors.tealAccent;

        return ListTile(
          dense: true,
          visualDensity: const VisualDensity(vertical: -1),
          leading: Icon(isArchive ? Icons.auto_stories : Icons.image, color: iconColor, size: 24),
          title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5)),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                item.formattedSize,
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
              IconButton(
                icon: const Icon(Icons.more_vert, size: 18, color: Colors.white54),
                tooltip: '옵션 더보기',
                onPressed: () => _showItemOperationsMenu(context, item),
              ),
            ],
          ),
          onTap: () => _openComicViewer(item),
          onLongPress: () => _showItemOperationsMenu(context, item),
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
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (item.id != '__ACTION_ADD_STORAGE__')
                  IconButton(
                    icon: const Icon(Icons.more_vert, size: 20, color: Colors.white54),
                    tooltip: '옵션 더보기',
                    onPressed: () => _showItemOperationsMenu(context, item),
                  ),
                const Icon(Icons.chevron_right, size: 20, color: Colors.white24),
              ],
            ),
            onTap: () => _navigateToFolder(item),
            onLongPress: item.id == '__ACTION_ADD_STORAGE__' ? null : () => _showItemOperationsMenu(context, item),
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
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.menu_book, color: Colors.blueAccent, size: 22),
                tooltip: '만화 열기',
                onPressed: () => _openComicViewer(item),
              ),
              IconButton(
                icon: const Icon(Icons.more_vert, size: 20, color: Colors.white54),
                tooltip: '옵션 더보기',
                onPressed: () => _showItemOperationsMenu(context, item),
              ),
            ],
          ),
          onTap: () => _openComicViewer(item),
          onLongPress: () => _showItemOperationsMenu(context, item),
        );
      },
    );
  }
}
