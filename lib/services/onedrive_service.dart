import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/media_item.dart';
import 'cloud_service_interface.dart';
import 'oauth_helper.dart';

class OneDriveService extends CloudService {
  OneDriveService(super.account, {super.onAccountUpdated});

  static const String defaultClientId = '4050ebc3-eb92-4fa8-bfe3-a1bfb0662d04';
  static const String authEndpoint = 'https://login.microsoftonline.com/common/oauth2/v2.0/authorize';
  static const String tokenEndpoint = 'https://login.microsoftonline.com/common/oauth2/v2.0/token';

  String get activeClientId => account.customClientId?.isNotEmpty == true
      ? account.customClientId!
      : defaultClientId;

  @override
  Future<bool> refreshTokensIfNeeded() async {
    if (!account.isTokenExpired) return true;
    if (account.refreshToken == null || account.refreshToken!.isEmpty) return false;

    try {
      final body = {
        'client_id': activeClientId,
        'refresh_token': account.refreshToken!,
        'grant_type': 'refresh_token',
      };
      if (account.customClientSecret?.isNotEmpty == true) {
        body['client_secret'] = account.customClientSecret!;
      }

      final res = await OAuthHelper.postWithRetry(
        Uri.parse(tokenEndpoint),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: body,
      );

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        account.accessToken = data['access_token'];
        if (data['refresh_token'] != null && (data['refresh_token'] as String).isNotEmpty) {
          account.refreshToken = data['refresh_token'];
        }
        final expiresIn = data['expires_in'] as int? ?? 3600;
        account.tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn));
        await onAccountUpdated?.call(account);
        return true;
      }
    } catch (_) {}
    return false;
  }

  @override
  Future<List<MediaItem>> listItems({String? folderId}) async {
    await refreshTokensIfNeeded();
    final url = (folderId == null || folderId == 'root')
        ? 'https://graph.microsoft.com/v1.0/me/drive/root/children?expand=thumbnails'
        : 'https://graph.microsoft.com/v1.0/me/drive/items/$folderId/children?expand=thumbnails';

    final res = await http.get(
      Uri.parse(url),
      headers: await getStreamHeaders(),
    );

    if (res.statusCode != 200) {
      throw Exception('원드라이브 파일 목록 조회 실패 (${res.statusCode}): ${res.body}');
    }

    final data = jsonDecode(res.body);
    final items = (data['value'] as List<dynamic>? ?? []);

    return items.map((f) {
      final isFolder = f.containsKey('folder');
      final size = f['size'] != null ? int.tryParse(f['size'].toString()) : null;
      final downloadUrl = f['@microsoft.graph.downloadUrl'] as String?;
      final thumbnails = f['thumbnails'] as List<dynamic>?;
      String? thumbUrl;
      if (thumbnails != null && thumbnails.isNotEmpty) {
        final t = thumbnails[0];
        thumbUrl = (t['large']?['url'] ?? t['medium']?['url'] ?? t['small']?['url']) as String?;
      }

      return MediaItem(
        id: f['id'] as String,
        name: f['name'] as String,
        parentId: folderId ?? 'root',
        isFolder: isFolder,
        size: size,
        thumbnailUrl: thumbUrl,
        directStreamUrl: downloadUrl,
        modifiedTime: f['lastModifiedDateTime'] != null
            ? DateTime.tryParse(f['lastModifiedDateTime'] as String)
            : null,
      );
    }).toList();
  }

  @override
  Future<String> getStreamUrl(MediaItem item) async {
    await refreshTokensIfNeeded();
    if (item.directStreamUrl != null && item.directStreamUrl!.isNotEmpty) {
      return item.directStreamUrl!;
    }

    final url = 'https://graph.microsoft.com/v1.0/me/drive/items/${item.id}';
    final res = await http.get(
      Uri.parse(url),
      headers: await getStreamHeaders(),
    );

    if (res.statusCode == 200) {
      final data = jsonDecode(res.body);
      final downloadUrl = data['@microsoft.graph.downloadUrl'] as String?;
      if (downloadUrl != null) return downloadUrl;
    }

    return 'https://graph.microsoft.com/v1.0/me/drive/items/${item.id}/content';
  }

  @override
  Future<Map<String, String>> getStreamHeaders() async {
    return {
      'Authorization': 'Bearer ${account.accessToken}',
    };
  }

  @override
  Future<String?> getThumbnailUrl(MediaItem item) async {
    if (item.thumbnailUrl != null && item.thumbnailUrl!.isNotEmpty) {
      return item.thumbnailUrl;
    }
    try {
      await refreshTokensIfNeeded();
      final url = 'https://graph.microsoft.com/v1.0/me/drive/items/${item.id}/thumbnails';
      final res = await http.get(Uri.parse(url), headers: await getStreamHeaders());
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final list = data['value'] as List<dynamic>?;
        if (list != null && list.isNotEmpty) {
          final t = list[0];
          return (t['large']?['url'] ?? t['medium']?['url'] ?? t['small']?['url']) as String?;
        }
      }
    } catch (_) {}
    return null;
  }

  @override
  Future<bool> renameItem(MediaItem item, String newName) async {
    try {
      await refreshTokensIfNeeded();
      final url = 'https://graph.microsoft.com/v1.0/me/drive/items/${item.id}';
      final headers = Map<String, String>.from(await getStreamHeaders())..['Content-Type'] = 'application/json';
      final res = await http.patch(Uri.parse(url), headers: headers, body: jsonEncode({'name': newName}));
      return res.statusCode == 200;
    } catch (e) {
      debugPrint('[OneDriveService] 이름 변경 실패: $e');
    }
    return false;
  }

  @override
  Future<bool> deleteItem(MediaItem item) async {
    try {
      await refreshTokensIfNeeded();
      final url = 'https://graph.microsoft.com/v1.0/me/drive/items/${item.id}';
      final res = await http.delete(Uri.parse(url), headers: await getStreamHeaders());
      return res.statusCode == 204 || res.statusCode == 200;
    } catch (e) {
      debugPrint('[OneDriveService] 삭제 실패: $e');
    }
    return false;
  }

  @override
  Future<bool> moveItem(
    MediaItem item,
    String targetFolderId, {
    String? newName,
    bool overwrite = false,
  }) async {
    try {
      await refreshTokensIfNeeded();
      final url = 'https://graph.microsoft.com/v1.0/me/drive/items/${item.id}';
      final headers = Map<String, String>.from(await getStreamHeaders())..['Content-Type'] = 'application/json';
      final parentId = (targetFolderId.isEmpty || targetFolderId == 'root') ? 'root' : targetFolderId;
      final bodyMap = <String, dynamic>{
        'parentReference': {'id': parentId},
      };
      if (newName != null && newName.isNotEmpty && newName != item.name) {
        bodyMap['name'] = newName;
      }
      final res = await http.patch(Uri.parse(url), headers: headers, body: jsonEncode(bodyMap));
      return res.statusCode == 200;
    } catch (e) {
      debugPrint('[OneDriveService] 이동 실패: $e');
    }
    return false;
  }

  @override
  Future<bool> copyItem(
    MediaItem item,
    String targetFolderId, {
    String? newName,
    bool overwrite = false,
  }) async {
    try {
      await refreshTokensIfNeeded();
      final url = 'https://graph.microsoft.com/v1.0/me/drive/items/${item.id}/copy';
      final headers = Map<String, String>.from(await getStreamHeaders())..['Content-Type'] = 'application/json';
      final parentId = (targetFolderId.isEmpty || targetFolderId == 'root') ? 'root' : targetFolderId;
      final bodyMap = <String, dynamic>{
        'parentReference': {'id': parentId},
      };
      if (newName != null && newName.isNotEmpty) {
        bodyMap['name'] = newName;
      }
      final res = await http.post(Uri.parse(url), headers: headers, body: jsonEncode(bodyMap));
      // OneDrive copy is asynchronous and returns 202 Accepted
      return res.statusCode == 202 || res.statusCode == 200;
    } catch (e) {
      debugPrint('[OneDriveService] 복사 실패: $e');
    }
    return false;
  }

  @override
  Future<bool> createFolder(String folderName, {String? parentFolderId}) async {
    try {
      await refreshTokensIfNeeded();
      final parentId = (parentFolderId == null || parentFolderId.isEmpty || parentFolderId == 'root') ? 'root' : parentFolderId;
      final url = 'https://graph.microsoft.com/v1.0/me/drive/items/$parentId/children';
      final headers = Map<String, String>.from(await getStreamHeaders())..['Content-Type'] = 'application/json';
      final body = jsonEncode({
        'name': folderName,
        'folder': {},
        '@microsoft.graph.conflictBehavior': 'rename',
      });
      final res = await http.post(Uri.parse(url), headers: headers, body: body);
      return res.statusCode == 201 || res.statusCode == 200;
    } catch (e) {
      debugPrint('[OneDriveService] 새 폴더 생성 실패: $e');
    }
    return false;
  }
}

