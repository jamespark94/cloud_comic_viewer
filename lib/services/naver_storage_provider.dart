import 'package:flutter/foundation.dart';
import '../models/media_item.dart';
import 'cloud_service_interface.dart';
import 'naver_box_api_client.dart';

class CloudFile {
  final String id;
  final String name;
  final int size;
  final bool isFolder;
  final String? parentId;
  final DateTime? modifiedTime;
  final String? thumbnailUrl;

  CloudFile({
    required this.id,
    required this.name,
    required this.size,
    required this.isFolder,
    this.parentId,
    this.modifiedTime,
    this.thumbnailUrl,
  });

  MediaItem toMediaItem() {
    return MediaItem(
      id: id,
      name: name,
      size: size,
      isFolder: isFolder,
      mimeType: isFolder ? 'folder' : _resolveMimeType(name),
      parentId: parentId,
      modifiedTime: modifiedTime,
      thumbnailUrl: thumbnailUrl,
    );
  }

  static String _resolveMimeType(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    switch (ext) {
      case 'zip':
      case 'cbz':
        return 'application/zip';
      case 'rar':
      case 'cbr':
        return 'application/x-rar-compressed';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      default:
        return 'application/octet-stream';
    }
  }
}

abstract class CloudStorageProvider {
  Future<List<CloudFile>> getFileList({String? path, String? folderId});
  Future<String> getDownloadUrl(String fileId);
  Future<Uint8List> getThumbnail(String fileId);
}

class NaverStorageProvider extends CloudService implements CloudStorageProvider {
  late final NaverBoxApiClient _apiClient;
  final Map<String, ({String url, DateTime expiry})> _streamUrlCache = {};

  NaverStorageProvider(
    super.account, {
    super.onAccountUpdated,
  }) {
    _initClient();
  }

  void _initClient() {
    _apiClient = NaverBoxApiClient(
      token: account.accessToken.trim(),
    );
  }

  @override
  Future<bool> refreshTokensIfNeeded() async {
    return account.accessToken.isNotEmpty;
  }

  @override
  Future<Map<String, String>> getStreamHeaders() async {
    // 네이버 MYBOX 다운로드 URL(downloadUrl)은 URL 쿼리 파라미터(atoken, resourceKey 등)로
    // 1회용 인증이 서명되어 있으므로, 다운로드/스트리밍 요청 시 Authorization 헤더나
    // 임의의 Referer/Origin을 붙이면 CDN/스토리지 서버에서 403 Forbidden을 반환합니다.
    return {
      'User-Agent': NaverBoxApiClient.defaultUserAgent,
    };
  }

  @override
  Future<List<CloudFile>> getFileList({String? path, String? folderId}) async {
    final list = await _apiClient.listFiles(folderId: folderId ?? path);
    return list.map((item) {
      return CloudFile(
        id: item.resourceId,
        name: item.name,
        size: item.size,
        isFolder: item.isFolder,
        parentId: item.parentId,
        modifiedTime: item.modifiedTime,
        thumbnailUrl: item.thumbnail,
      );
    }).toList();
  }

  @override
  Future<String> getDownloadUrl(String fileId) async {
    return _apiClient.getDownloadUrl(fileId);
  }

  @override
  Future<Uint8List> getThumbnail(String fileId) async {
    return _apiClient.getThumbnail(fileId);
  }

  @override
  Future<List<MediaItem>> listItems({String? folderId}) async {
    final cloudFiles = await getFileList(folderId: folderId);
    return cloudFiles.map((file) => file.toMediaItem()).toList();
  }

  @override
  void invalidateStreamUrl(MediaItem item) {
    _streamUrlCache.remove(item.id);
  }

  @override
  Future<String> getStreamUrl(MediaItem item) async {
    final cached = _streamUrlCache[item.id];
    if (cached != null && DateTime.now().isBefore(cached.expiry)) {
      return cached.url;
    }

    // 네이버 MYBOX 다운로드 URL 발급 API (/v1/drive/files/{fileId}/download)
    // 반환된 downloadUrl은 이미 스토리지 서명(atoken, auth=3 등)이 포함된 직링크입니다.
    final rawDownloadUrl = await getDownloadUrl(item.id);

    // 네이버 임시 서명 URL은 10분(600초) 유효하므로 안전하게 8분 캐싱
    _streamUrlCache[item.id] = (
      url: rawDownloadUrl,
      expiry: DateTime.now().add(const Duration(minutes: 8)),
    );

    return rawDownloadUrl;
  }
}
