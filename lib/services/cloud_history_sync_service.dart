import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/cloud_account.dart';
import '../models/comic_reading_history.dart';
import 'account_manager.dart';
import 'cloud_service_interface.dart';
import 'reading_history_service.dart';

/// 클라우드 기반 디바이스 간 열람 기록(히스토리) 동기화 서비스
/// 클라우드 스토리지의 `.comic_sync/reading_history.json` 파일을 사용하여
/// PC, 태블릿, 스마트폰 등 다중 기기 간 만화책 읽기 진도를 자동/수동 동기화합니다.
class CloudHistorySyncService extends ChangeNotifier {
  static CloudHistorySyncService? _instance;
  static CloudHistorySyncService get instance => _instance ??= CloudHistorySyncService._();

  CloudHistorySyncService._();

  static const String syncFolderName = '.comic_sync';
  static const String syncFileName = 'reading_history.json';

  bool _isSyncing = false;
  bool get isSyncing => _isSyncing;

  DateTime? _lastSyncTime;
  DateTime? get lastSyncTime => _lastSyncTime;

  String? _lastSyncMessage;
  String? get lastSyncMessage => _lastSyncMessage;

  /// 연결된 클라우드 계정과 동기화 실행 (Pull & Merge -> Push)
  Future<bool> syncHistories(AccountManager accountManager) async {
    if (_isSyncing) return false;

    final cloudAccounts = accountManager.accounts.where((a) => a.type != CloudType.local).toList();
    if (cloudAccounts.isEmpty) {
      _lastSyncMessage = '동기화할 클라우드 계정이 연결되어 있지 않습니다.';
      notifyListeners();
      return false;
    }

    _isSyncing = true;
    _lastSyncMessage = '클라우드 히스토리 동기화 중...';
    notifyListeners();

    bool anySuccess = false;
    int mergedCount = 0;

    for (final account in cloudAccounts) {
      try {
        final service = accountManager.getService(account);
        await service.refreshTokensIfNeeded();

        // 1. 원격 히스토리 파일 가져오기
        final remoteJsonStr = await _fetchRemoteHistoryJson(service, account);
        List<ComicReadingHistory> remoteHistories = [];

        if (remoteJsonStr != null && remoteJsonStr.isNotEmpty) {
          try {
            final data = jsonDecode(remoteJsonStr);
            final List<dynamic> list = data is Map ? (data['histories'] as List<dynamic>? ?? []) : (data as List<dynamic>);
            remoteHistories = list.map((e) => ComicReadingHistory.fromJson(e as Map<String, dynamic>)).toList();
          } catch (e) {
            debugPrint('[CloudSync] 원격 JSON 파싱 실패: $e');
          }
        }

        // 2. 로컬 히스토리와 스마트 병합
        final mergedList = await ReadingHistoryService.instance.mergeWithRemote(remoteHistories);
        mergedCount = mergedList.length;

        // 3. 최신 병합본을 원격 클라우드에 업로드
        final syncData = {
          'version': 1,
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
          'count': mergedList.length,
          'histories': mergedList.map((e) => e.toJson()).toList(),
        };
        final payload = jsonEncode(syncData);
        final uploadOk = await _uploadRemoteHistoryJson(service, account, payload);

        if (uploadOk) {
          anySuccess = true;
        }
      } catch (e) {
        debugPrint('[CloudSync] 계정(${account.name}) 동기화 중 예외: $e');
      }
    }

    _isSyncing = false;
    if (anySuccess) {
      _lastSyncTime = DateTime.now();
      _lastSyncMessage = '동기화 완료 ($mergedCount개 작품 진도 동기화됨)';
    } else {
      _lastSyncMessage = '동기화 실패: 네트워크 상태 또는 클라우드 연결을 확인해 주세요.';
    }
    notifyListeners();
    return anySuccess;
  }

  // ============================================================
  // 각 클라우드 스토리지별 원격 히스토리 읽기 (Fetch)
  // ============================================================
  Future<String?> _fetchRemoteHistoryJson(CloudService service, CloudAccount account) async {
    switch (account.type) {
      case CloudType.googleDrive:
        return await _fetchGoogleDrive(service, account);
      case CloudType.webDav:
        return await _fetchWebDav(service, account);
      case CloudType.oneDrive:
        return await _fetchOneDrive(service, account);
      case CloudType.dropbox:
        return await _fetchDropbox(service, account);
      default:
        return null;
    }
  }

  // ============================================================
  // 각 클라우드 스토리지별 원격 히스토리 쓰기 (Upload)
  // ============================================================
  Future<bool> _uploadRemoteHistoryJson(CloudService service, CloudAccount account, String jsonPayload) async {
    switch (account.type) {
      case CloudType.googleDrive:
        return await _uploadGoogleDrive(service, account, jsonPayload);
      case CloudType.webDav:
        return await _uploadWebDav(service, account, jsonPayload);
      case CloudType.oneDrive:
        return await _uploadOneDrive(service, account, jsonPayload);
      case CloudType.dropbox:
        return await _uploadDropbox(service, account, jsonPayload);
      default:
        return false;
    }
  }

  // ------------------------------------------------------------
  // Google Drive 구현
  // ------------------------------------------------------------
  Future<String?> _fetchGoogleDrive(CloudService service, CloudAccount account) async {
    final headers = await service.getStreamHeaders();

    // 1. '.comic_sync' 폴더 검색
    final folderQuery = Uri.encodeComponent("name = '$syncFolderName' and mimeType = 'application/vnd.google-apps.folder' and trashed = false");
    final folderRes = await http.get(
      Uri.parse('https://www.googleapis.com/drive/v3/files?q=$folderQuery&fields=files(id)'),
      headers: headers,
    );
    if (folderRes.statusCode != 200) return null;
    final folderFiles = (jsonDecode(folderRes.body)['files'] as List<dynamic>? ?? []);
    if (folderFiles.isEmpty) return null;
    final folderId = folderFiles.first['id'] as String;

    // 2. 'reading_history.json' 파일 검색
    final fileQuery = Uri.encodeComponent("'$folderId' in parents and name = '$syncFileName' and trashed = false");
    final fileRes = await http.get(
      Uri.parse('https://www.googleapis.com/drive/v3/files?q=$fileQuery&fields=files(id)'),
      headers: headers,
    );
    if (fileRes.statusCode != 200) return null;
    final files = (jsonDecode(fileRes.body)['files'] as List<dynamic>? ?? []);
    if (files.isEmpty) return null;
    final fileId = files.first['id'] as String;

    // 3. 파일 내용 다운로드
    final downloadRes = await http.get(
      Uri.parse('https://www.googleapis.com/drive/v3/files/$fileId?alt=media'),
      headers: headers,
    );
    if (downloadRes.statusCode == 200) {
      return utf8.decode(downloadRes.bodyBytes);
    }
    return null;
  }

  Future<bool> _uploadGoogleDrive(CloudService service, CloudAccount account, String payload) async {
    final headers = await service.getStreamHeaders();

    // 1. '.comic_sync' 폴더 확인 또는 생성
    String? folderId;
    final folderQuery = Uri.encodeComponent("name = '$syncFolderName' and mimeType = 'application/vnd.google-apps.folder' and trashed = false");
    final folderRes = await http.get(
      Uri.parse('https://www.googleapis.com/drive/v3/files?q=$folderQuery&fields=files(id)'),
      headers: headers,
    );
    if (folderRes.statusCode == 200) {
      final folderFiles = (jsonDecode(folderRes.body)['files'] as List<dynamic>? ?? []);
      if (folderFiles.isNotEmpty) {
        folderId = folderFiles.first['id'] as String;
      }
    }

    if (folderId == null) {
      // 폴더 신규 생성
      final createFolderRes = await http.post(
        Uri.parse('https://www.googleapis.com/drive/v3/files'),
        headers: {
          ...headers,
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'name': syncFolderName,
          'mimeType': 'application/vnd.google-apps.folder',
        }),
      );
      if (createFolderRes.statusCode == 200 || createFolderRes.statusCode == 201) {
        folderId = jsonDecode(createFolderRes.body)['id'] as String;
      } else {
        return false;
      }
    }

    // 2. 파일 존재 여부 확인
    String? existingFileId;
    final fileQuery = Uri.encodeComponent("'$folderId' in parents and name = '$syncFileName' and trashed = false");
    final fileRes = await http.get(
      Uri.parse('https://www.googleapis.com/drive/v3/files?q=$fileQuery&fields=files(id)'),
      headers: headers,
    );
    if (fileRes.statusCode == 200) {
      final files = (jsonDecode(fileRes.body)['files'] as List<dynamic>? ?? []);
      if (files.isNotEmpty) {
        existingFileId = files.first['id'] as String;
      }
    }

    if (existingFileId != null) {
      // 기존 파일 업데이트 (PATCH media)
      final updateRes = await http.patch(
        Uri.parse('https://www.googleapis.com/upload/drive/v3/files/$existingFileId?uploadType=media'),
        headers: {
          ...headers,
          'Content-Type': 'application/json; charset=utf-8',
        },
        body: utf8.encode(payload),
      );
      return updateRes.statusCode == 200;
    } else {
      // 신규 파일 생성 (Multipart 업로드)
      final boundary = '----WebKitFormBoundary${DateTime.now().millisecondsSinceEpoch}';
      final metadata = jsonEncode({
        'name': syncFileName,
        'parents': [folderId],
        'mimeType': 'application/json',
      });

      final bodyBytes = <int>[
        ...utf8.encode('--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n$metadata\r\n'),
        ...utf8.encode('--$boundary\r\nContent-Type: application/json\r\n\r\n$payload\r\n'),
        ...utf8.encode('--$boundary--\r\n'),
      ];

      final createRes = await http.post(
        Uri.parse('https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart'),
        headers: {
          ...headers,
          'Content-Type': 'multipart/related; boundary=$boundary',
        },
        body: bodyBytes,
      );
      return createRes.statusCode == 200 || createRes.statusCode == 201;
    }
  }

  // ------------------------------------------------------------
  // WebDAV 구현
  // ------------------------------------------------------------
  Future<String?> _fetchWebDav(CloudService service, CloudAccount account) async {
    final baseUrl = account.webDavUrl?.replaceAll(RegExp(r'/+$'), '') ?? '';
    if (baseUrl.isEmpty) return null;
    final headers = await service.getStreamHeaders();

    final fileUrl = '$baseUrl/$syncFolderName/$syncFileName';
    final res = await http.get(Uri.parse(fileUrl), headers: headers);
    if (res.statusCode == 200) {
      return utf8.decode(res.bodyBytes);
    }
    return null;
  }

  Future<bool> _uploadWebDav(CloudService service, CloudAccount account, String payload) async {
    final baseUrl = account.webDavUrl?.replaceAll(RegExp(r'/+$'), '') ?? '';
    if (baseUrl.isEmpty) return false;
    final headers = await service.getStreamHeaders();

    // 1. 디렉터리 생성 (MKCOL)
    try {
      final mkcolReq = http.Request('MKCOL', Uri.parse('$baseUrl/$syncFolderName'));
      mkcolReq.headers.addAll(headers);
      await mkcolReq.send();
    } catch (_) {}

    // 2. 파일 PUT
    final fileUrl = '$baseUrl/$syncFolderName/$syncFileName';
    final putRes = await http.put(
      Uri.parse(fileUrl),
      headers: {
        ...headers,
        'Content-Type': 'application/json; charset=utf-8',
      },
      body: utf8.encode(payload),
    );
    return putRes.statusCode == 200 || putRes.statusCode == 201 || putRes.statusCode == 204;
  }

  // ------------------------------------------------------------
  // OneDrive 구현
  // ------------------------------------------------------------
  Future<String?> _fetchOneDrive(CloudService service, CloudAccount account) async {
    final headers = await service.getStreamHeaders();
    final url = 'https://graph.microsoft.com/v1.0/me/drive/root:/$syncFolderName/$syncFileName:/content';
    final res = await http.get(Uri.parse(url), headers: headers);
    if (res.statusCode == 200) {
      return utf8.decode(res.bodyBytes);
    }
    return null;
  }

  Future<bool> _uploadOneDrive(CloudService service, CloudAccount account, String payload) async {
    final headers = await service.getStreamHeaders();
    final url = 'https://graph.microsoft.com/v1.0/me/drive/root:/$syncFolderName/$syncFileName:/content';
    final res = await http.put(
      Uri.parse(url),
      headers: {
        ...headers,
        'Content-Type': 'application/json; charset=utf-8',
      },
      body: utf8.encode(payload),
    );
    return res.statusCode == 200 || res.statusCode == 201;
  }

  // ------------------------------------------------------------
  // Dropbox 구현
  // ------------------------------------------------------------
  Future<String?> _fetchDropbox(CloudService service, CloudAccount account) async {
    final headers = await service.getStreamHeaders();
    final url = 'https://content.dropboxapi.com/2/files/download';
    final res = await http.post(
      Uri.parse(url),
      headers: {
        ...headers,
        'Dropbox-API-Arg': jsonEncode({'path': '/$syncFolderName/$syncFileName'}),
      },
    );
    if (res.statusCode == 200) {
      return utf8.decode(res.bodyBytes);
    }
    return null;
  }

  Future<bool> _uploadDropbox(CloudService service, CloudAccount account, String payload) async {
    final headers = await service.getStreamHeaders();
    final url = 'https://content.dropboxapi.com/2/files/upload';
    final res = await http.post(
      Uri.parse(url),
      headers: {
        ...headers,
        'Dropbox-API-Arg': jsonEncode({
          'path': '/$syncFolderName/$syncFileName',
          'mode': 'overwrite',
          'autorename': false,
          'mute': false,
        }),
        'Content-Type': 'application/octet-stream',
      },
      body: utf8.encode(payload),
    );
    return res.statusCode == 200;
  }
}
