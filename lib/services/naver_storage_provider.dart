import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import '../models/cloud_account.dart';
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
    return _apiClient.authHeaders;
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
  Future<String> getStreamUrl(MediaItem item) async {
    return getDownloadUrl(item.id);
  }
}
