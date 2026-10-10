import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/media_item.dart';
import '../utils/permission_utils.dart';
import 'cloud_service_interface.dart';

class LocalDiskService extends CloudService {
  static const String customStoragePrefKey = 'custom_comic_storage_paths';

  LocalDiskService(super.account, {super.onAccountUpdated});

  @override
  Future<List<MediaItem>> listItems({String? folderId}) async {
    // Android 저장소 권한 선제적 확인/요청
    if (Platform.isAndroid) {
      await PermissionUtils.ensureStoragePermission();
    }

    // 1. 루트 목록 (드라이브, SD 카드, 사용자 추가 저장소 및 빠른 접근)
    if (folderId == null || folderId.isEmpty) {
      return await _getRootSources();
    }

    // 2. 특정 로컬 폴더 내 파일 및 서브 폴더 조회
    final targetDir = Directory(folderId);
    if (!await targetDir.exists()) {
      return [];
    }

    final List<MediaItem> folders = [];
    final List<MediaItem> mediaFiles = [];

    List<FileSystemEntity> entities = [];
    try {
      entities = targetDir.listSync(followLinks: true);
    } on FileSystemException catch (e) {
      try {
        entities = targetDir.listSync(followLinks: false);
      } catch (_) {
        if (e.osError?.errorCode == 13 || e.message.toLowerCase().contains('permission denied')) {
          throw Exception('저장소 접근 권한이 필요합니다. 기기 설정에서 앱의 저장소/사진 권한을 허용해 주세요.');
        }
        rethrow;
      }
    }

    for (final entity in entities) {
      final name = _getBasename(entity.path);

      // 숨김 파일 및 시스템 폴더 제외
      if (name.startsWith('.') ||
          name.startsWith('\$') ||
          name.equalsIgnoreCase('System Volume Information') ||
          name.equalsIgnoreCase('Windows') ||
          name.equalsIgnoreCase('Recovery') ||
          name.equalsIgnoreCase('dumpstack.log.tmp')) {
        continue;
      }

      bool isDir = false;
      try {
        final stat = entity.statSync();
        isDir = stat.type == FileSystemEntityType.directory;
      } catch (_) {
        isDir = entity is Directory;
      }

      if (isDir) {
        folders.add(
          MediaItem(
            id: entity.path,
            name: name,
            isFolder: true,
            parentId: folderId,
          ),
        );
      } else {
        // 파일인 경우: 만화책 압축 파일(ZIP/CBZ 등) 또는 이미지인지 검사
        final tempItem = MediaItem(
          id: entity.path,
          name: name,
          isFolder: false,
        );

        if (tempItem.isComicArchive || tempItem.isImage) {
          int? size;
          DateTime? modified;
          try {
            final stat = entity.statSync();
            size = stat.size;
            modified = stat.modified;
          } catch (_) {}

          mediaFiles.add(
            MediaItem(
              id: entity.path,
              name: name,
              isFolder: false,
              parentId: folderId,
              size: size,
              modifiedTime: modified,
              directStreamUrl: entity.path,
            ),
          );
        }
      }
    }

    // 정렬: 폴더 가나다순, 그 다음 파일 가나다순
    folders.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    mediaFiles.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return [...folders, ...mediaFiles];
  }

  /// 루트(홈) 진입 시 보여줄 드라이브, SD 카드 및 빠른 접근 폴더 목록
  Future<List<MediaItem>> _getRootSources() async {
    final List<MediaItem> items = [];

    // [특수 액션] 사용자가 직접 SD 카드나 다른 폴더를 추가할 수 있는 버튼
    items.add(
      MediaItem(
        id: '__ACTION_ADD_STORAGE__',
        name: '➕ 다른 저장소 / SD 카드 폴더 직접 추가',
        isFolder: true,
      ),
    );

    if (Platform.isWindows) {
      // 1. Windows 빠른 접근 폴더
      final userProfile = Platform.environment['USERPROFILE'];
      if (userProfile != null && userProfile.isNotEmpty) {
        final quickFolders = [
          {'name': '📁 사진 / 이미지', 'sub': 'Pictures'},
          {'name': '📁 다운로드 폴더', 'sub': 'Downloads'},
          {'name': '📁 바탕 화면', 'sub': 'Desktop'},
          {'name': '📁 문서 폴더', 'sub': 'Documents'},
        ];

        for (final qf in quickFolders) {
          final path = '$userProfile\\${qf['sub']}';
          if (Directory(path).existsSync()) {
            items.add(
              MediaItem(
                id: path,
                name: qf['name']!,
                isFolder: true,
              ),
            );
          }
        }
      }

      // 2. Windows 드라이브 문자 스캔 (C:\, D:\ 등)
      final drives = [
        'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K',
        'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T',
        'U', 'V', 'W', 'X', 'Y', 'Z'
      ];

      for (final letter in drives) {
        final drivePath = '$letter:\\';
        try {
          if (Directory(drivePath).existsSync()) {
            items.add(
              MediaItem(
                id: drivePath,
                name: '💾 로컬 디스크 ($letter:)',
                isFolder: true,
              ),
            );
          }
        } catch (_) {}
      }
    } else if (Platform.isAndroid) {
      // 1. Android 외장 SD 카드/USB 자동 감지
      try {
        final extDirs = await getExternalStorageDirectories();
        if (extDirs != null) {
          for (final dir in extDirs) {
            final path = dir.path;
            final match = RegExp(r'^(/storage/[^/]+)/Android').firstMatch(path);
            if (match != null) {
              final rootPath = match.group(1)!;
              final bName = _getBasename(rootPath);
              if (!bName.equalsIgnoreCase('emulated') &&
                  !bName.equalsIgnoreCase('self') &&
                  !bName.equalsIgnoreCase('knox')) {
                if (!items.any((it) => it.id == rootPath)) {
                  items.add(
                    MediaItem(
                      id: rootPath,
                      name: '💾 외장 SD 카드 ($bName)',
                      isFolder: true,
                    ),
                  );
                }
              }
            }
          }
        }
      } catch (_) {}

      // 2. Android 기본 내부 저장소 및 퀵 링크
      final androidPaths = [
        {'name': '📱 다운로드 (Downloads)', 'path': '/storage/emulated/0/Download'},
        {'name': '📱 사진/그림 (Pictures)', 'path': '/storage/emulated/0/Pictures'},
        {'name': '📱 DCIM (갤러리)', 'path': '/storage/emulated/0/DCIM'},
        {'name': '📱 문서 (Documents)', 'path': '/storage/emulated/0/Documents'},
        {'name': '📱 내부 저장소 전체', 'path': '/storage/emulated/0'},
      ];

      for (final ap in androidPaths) {
        final path = ap['path']!;
        if (Directory(path).existsSync()) {
          items.add(
            MediaItem(
              id: path,
              name: ap['name']!,
              isFolder: true,
            ),
          );
        }
      }

      // 3. /storage 직접 스캔
      try {
        final storageDir = Directory('/storage');
        if (storageDir.existsSync()) {
          final entries = storageDir.listSync(followLinks: false);
          for (final entry in entries) {
            final bName = _getBasename(entry.path);
            if (!bName.equalsIgnoreCase('emulated') &&
                !bName.equalsIgnoreCase('self') &&
                !bName.equalsIgnoreCase('knox') &&
                !bName.startsWith('.')) {
              if (!items.any((it) => it.id == entry.path)) {
                items.add(
                  MediaItem(
                    id: entry.path,
                    name: '💾 SD 카드 / 외장 저장소 ($bName)',
                    isFolder: true,
                  ),
                );
              }
            }
          }
        }
      } catch (_) {}
    } else {
      // macOS, Linux
      final home = Platform.environment['HOME'];
      if (home != null) {
        final pictures = '$home/Pictures';
        final downloads = '$home/Downloads';
        if (Directory(pictures).existsSync()) {
          items.add(MediaItem(id: pictures, name: '📁 사진', isFolder: true));
        }
        if (Directory(downloads).existsSync()) {
          items.add(MediaItem(id: downloads, name: '📁 다운로드', isFolder: true));
        }
        items.add(MediaItem(id: home, name: '📁 홈 폴더', isFolder: true));
      }
    }

    // 4. 사용자가 직접 추가한 커스텀 저장소/폴더 목록 불러오기
    try {
      final customPaths = await getCustomStoragePaths();
      for (final cp in customPaths) {
        if (!items.any((it) => it.id == cp) && Directory(cp).existsSync()) {
          items.add(
            MediaItem(
              id: cp,
              name: '📂 사용자 추가 저장소 (${_getBasename(cp)})',
              isFolder: true,
            ),
          );
        }
      }
    } catch (_) {}

    return items;
  }

  /// 사용자가 추가한 커스텀 저장소 경로 목록 조회
  static Future<List<String>> getCustomStoragePaths() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(customStoragePrefKey) ?? [];
  }

  /// 새로운 커스텀 저장소/폴더 경로 추가
  static Future<void> addCustomStoragePath(String path) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(customStoragePrefKey) ?? [];
    if (!list.contains(path)) {
      list.add(path);
      await prefs.setStringList(customStoragePrefKey, list);
    }
  }

  /// 커스텀 저장소 경로 삭제
  static Future<void> removeCustomStoragePath(String path) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(customStoragePrefKey) ?? [];
    list.remove(path);
    await prefs.setStringList(customStoragePrefKey, list);
  }

  String _getBasename(String path) {
    var clean = path;
    if (clean.endsWith('\\') || clean.endsWith('/')) {
      clean = clean.substring(0, clean.length - 1);
    }
    final lastSep = clean.lastIndexOf(RegExp(r'[\\/]'));
    if (lastSep == -1) return clean;
    return clean.substring(lastSep + 1);
  }

  @override
  Future<String> getStreamUrl(MediaItem item) async {
    return item.id;
  }

  @override
  Future<Map<String, String>> getStreamHeaders() async {
    return const {};
  }

  @override
  Future<bool> refreshTokensIfNeeded() async {
    return true;
  }

  @override
  Future<Uint8List> downloadBytes(
    MediaItem item, {
    void Function(int received, int total)? onProgress,
  }) async {
    final file = File(item.id);
    if (!await file.exists()) {
      throw Exception('로컬 파일이 존재하지 않습니다: ${item.id}');
    }
    final bytes = await file.readAsBytes();
    if (onProgress != null) {
      onProgress(bytes.length, bytes.length);
    }
    return bytes;
  }

  @override
  Future<String?> getThumbnailUrl(MediaItem item) async {
    return null;
  }
}

extension on String {
  bool equalsIgnoreCase(String other) => toLowerCase() == other.toLowerCase();
}
