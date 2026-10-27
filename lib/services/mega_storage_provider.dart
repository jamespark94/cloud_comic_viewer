import 'package:flutter/foundation.dart';
import '../models/media_item.dart';
import '../utils/mega_crypto_utils.dart';
import 'cloud_service_interface.dart';
import 'mega_api_client.dart';
import 'naver_storage_provider.dart';

/// Isolate compute용 파일 복호화 레코드 및 탑레벨 함수
typedef _DecryptParams = ({
  Uint8List encryptedBytes,
  Uint8List aesKey,
  Uint8List iv,
});

Uint8List _decryptIsolateEntry(_DecryptParams params) {
  return MegaCryptoUtils.decryptFileBytesCtr(
    encryptedBytes: params.encryptedBytes,
    fileAesKey16: params.aesKey,
    fileIv8: params.iv,
  );
}

class MegaStorageProvider extends CloudService implements CloudStorageProvider {
  MegaApiClient? _apiClient;

  /// 다운로드 URL 임시 캐시
  final Map<String, ({String url, DateTime expiry})> _downloadUrlCache = {};

  MegaStorageProvider(
    super.account, {
    super.onAccountUpdated,
  });

  /// `flutter_secure_storage` 또는 `account` 필드에서 `sid`와 `masterKey`를 로드하여 `MegaApiClient` 초기화
  Future<MegaApiClient> _ensureClient() async {
    if (_apiClient != null) {
      return _apiClient!;
    }

    String? sid;
    Uint8List? masterKey;

    // 1. FlutterSecureStorage에서 조회
    final creds = await MegaAuthManager.loadCredentials(
      account.id,
      email: account.email,
    );

    if (creds != null) {
      sid = creds.sid;
      masterKey = creds.masterKey;
    } else {
      // 2. 폴백: account.accessToken 및 refreshToken 확인
      if (account.accessToken.isNotEmpty) {
        sid = account.accessToken;
      }
      if (account.refreshToken != null && account.refreshToken!.isNotEmpty) {
        try {
          masterKey = MegaCryptoUtils.base64UrlDecode(account.refreshToken!);
        } catch (_) {}
      }
    }

    if (sid == null || sid.isEmpty || masterKey == null || masterKey.isEmpty) {
      throw Exception('MEGA 인증 자격증명(세션 토큰 또는 마스터 키)을 찾을 수 없습니다.');
    }

    _apiClient = MegaApiClient(sid: sid, masterKey: masterKey);
    return _apiClient!;
  }

  @override
  Future<bool> refreshTokensIfNeeded() async {
    try {
      await _ensureClient();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<Map<String, String>> getStreamHeaders() async {
    return const {};
  }

  // ===========================================================================
  // CloudStorageProvider 인터페이스 구현
  // ===========================================================================

  @override
  Future<List<CloudFile>> getFileList({String? path, String? folderId}) async {
    final client = await _ensureClient();
    final nodes = await client.listFiles(folderId: folderId ?? path);

    return nodes.map((node) {
      return CloudFile(
        id: node.handle,
        name: node.name,
        size: node.size,
        isFolder: node.isFolder,
        parentId: node.parentId,
        modifiedTime: node.modifiedTime,
      );
    }).toList();
  }

  @override
  Future<String> getDownloadUrl(String fileId) async {
    final cached = _downloadUrlCache[fileId];
    if (cached != null && DateTime.now().isBefore(cached.expiry)) {
      return cached.url;
    }

    final client = await _ensureClient();
    final res = await client.getEncryptedDownloadUrl(fileId);

    // MEGA 다운로드 URL은 임시 URL이므로 15분 캐싱
    _downloadUrlCache[fileId] = (
      url: res.downloadUrl,
      expiry: DateTime.now().add(const Duration(minutes: 15)),
    );

    return res.downloadUrl;
  }

  @override
  Future<Uint8List> getThumbnail(String fileId) async {
    return getDecryptedFileBytes(fileId);
  }

  // ===========================================================================
  // 핵심 요구사항: 암호화 파일 다운로드 + AES-128-CTR 복호화 파이프라인
  // ===========================================================================

  /// 파일 ID(`handle`)로 암호화 바이너리를 다운로드하고,
  /// 해당 노드의 고유 키(16B)와 IV/Nonce(8B)로 AES-128-CTR 복호화한 순수 바이트(`Uint8List`)를 반환합니다.
  Future<Uint8List> getDecryptedFileBytes(
    String fileId, {
    void Function(int received, int total)? onProgress,
  }) async {
    final client = await _ensureClient();
    final node = await client.getNodeById(fileId);
    if (node == null || node.decryptedKey == null) {
      throw Exception('MEGA 파일 정보를 찾을 수 없거나 복호화 키가 없습니다. ($fileId)');
    }

    final downloadUrl = await getDownloadUrl(fileId);
    final encryptedBytes = await client.downloadEncryptedBytes(
      downloadUrl,
      onProgress: onProgress,
    );

    // 용량이 1MB 이상인 경우 compute를 통해 백그라운드 Isolate에서 복호화
    if (encryptedBytes.length > 1024 * 1024) {
      return await compute(
        _decryptIsolateEntry,
        (
          encryptedBytes: encryptedBytes,
          aesKey: node.decryptedKey!.aesKey,
          iv: node.decryptedKey!.iv,
        ),
      );
    } else {
      return MegaCryptoUtils.decryptFileBytesCtr(
        encryptedBytes: encryptedBytes,
        fileAesKey16: node.decryptedKey!.aesKey,
        fileIv8: node.decryptedKey!.iv,
      );
    }
  }

  // ===========================================================================
  // CloudService 인터페이스 연동 (ComicViewerScreen & ComicCacheManager 호환)
  // ===========================================================================

  @override
  Future<List<MediaItem>> listItems({String? folderId}) async {
    final files = await getFileList(folderId: folderId);
    return files.map((f) => f.toMediaItem()).toList();
  }

  /// 파일의 복호화 키(MegaFileKey) 조회
  Future<MegaFileKey?> getFileKey(String fileId) async {
    final client = await _ensureClient();
    final node = await client.getNodeById(fileId);
    return node?.decryptedKey;
  }

  @override
  Future<String> getStreamUrl(MediaItem item) async {
    // MEGA 파일은 암호화된 스트림이므로 전체 다운로드 및 복호화(downloadBytes)를 우선 유도
    return await getDownloadUrl(item.id);
  }

  @override
  void invalidateStreamUrl(MediaItem item) {
    _downloadUrlCache.remove(item.id);
  }

  /// ComicCacheManager 및 ComicViewerScreen이 파일/이미지를 로드할 때 호출하는 메서드.
  /// 순수 복호화된 Uint8List 평문 바이트를 반환합니다.
  @override
  Future<Uint8List> downloadBytes(
    MediaItem item, {
    void Function(int received, int total)? onProgress,
  }) async {
    return getDecryptedFileBytes(item.id, onProgress: onProgress);
  }
}
