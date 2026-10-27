# MEGA Cloud (메가 클라우드) 연결 및 E2EE 복호화 구현 계획서

> **목적**: 다른 AI 모델 또는 새 세션에서 즉시 참조하여 **MEGA Cloud (E2EE 종단간 암호화)** 연동을 오류 없이 구현할 수 있도록 작성된 상세 설계 및 코드 뼈대 명세서입니다.  
> **대상 프로젝트**: `D:\My Documents\AI\cloud_comic_viewer` (Flutter 만화 뷰어 앱)

---

## 1. 아키텍처 개요 및 핵심 설계 전략

MEGA 클라우드는 서버에 저장된 파일명, 폴더 구조, 파일 바이너리 전체가 클라이언트 측 마스터 키(`Master Key`) 및 노드 키(`Node Key`)로 암호화되는 **E2EE(End-to-End Encryption)** 스토리지입니다.

따라서 기존 일반 HTTP 스트리밍 클라우드와 달리 아래 파이프라인을 거쳐야 합니다:
1. **인증 및 마스터 키 유도 (`MegaAuthManager` / `MegaCryptoUtils`)**:
   - 이메일/비밀번호로 MEGA v1(Legacy) 또는 v2(PBKDF2-HMAC-SHA512) 로그인 챌린지(`us0`)를 수행하여 암호화된 마스터 키(`k`), 세션 복구용 개인키(`privk` / `csid`) 또는 세션 토큰(`sid`)을 획득합니다.
   - 복호화된 **16바이트 마스터 키(Master Key)**와 **세션 ID(`sid`)**를 `flutter_secure_storage` 및 `CloudAccount`에 안전하게 보관합니다.
2. **노드 트리 조회 및 메타데이터 복호화 (`MegaApiClient`)**:
   - `POST https://g.api.mega.co.nz/cs?id={seq}&sid={sid}` (`[{"a": "f", "c": 1, "r": 1}]`) 호출로 전체 파일/폴더 트리를 1회 로드하고 메모리에 캐싱합니다.
   - 각 노드의 `k` (`ownerHandle:base64NodeKey`)를 마스터 키로 AES-128-ECB 복호화합니다.
   - 파일 노드의 경우 32바이트(256비트) 키를 언패킹(XOR)하여 **16바이트 파일 AES 키**와 **8바이트 IV(Nonce)**를 분리합니다.
   - 암호화된 속성 문자열(`a`)을 복호화하여 `MEGA{"n":"파일명"}` JSON에서 실제 파일명과 확장자를 추출합니다.
3. **바이너리 다운로드 및 AES-128-CTR 복호화 (`MegaStorageProvider`)**:
   - `[{"a": "g", "g": 1, "n": "{nodeHandle}"}]` 요청으로 임시 암호화 다운로드 URL(`g`)을 발급받습니다.
   - **핵심 주의사항**: MEGA의 파일 바이너리는 `AES-128-CTR`로 전체 암호화되어 있어, 일반 `HttpCloudRangeReader`가 암호문 상태에서 바로 ZIP 시그니처(`0x504B0506`)를 찾으면 실패합니다.
   - 따라서 `MegaStorageProvider`는:
     - `getDecryptedFileBytes(String fileId)` 및 `CloudService.downloadBytes(MediaItem item)`에서 **암호화 바이너리 다운로드 후 즉시 `AES-128-CTR` 복호화를 수행한 순수 평문 `Uint8List`**를 반환하도록 오버라이드합니다.
     - (선택적 고급 지원) 16바이트 블록 오프셋(`blockIndex = start ~/ 16`) 기반의 CTR Counter 계산을 통해 Range 복호화도 가능하도록 유틸리티를 설계합니다.

---

## 2. 의존성 패키지 구성 (`pubspec.yaml`)

현재 `pubspec.yaml`에 `dio: ^5.11.1`, `flutter_secure_storage: ^11.2.0`, `crypto: ^3.0.7`은 이미 설치되어 있습니다.  
MEGA의 `AES-128-ECB`, `AES-128-CBC`, `AES-128-CTR` 및 `PBKDF2` 처리를 위해 **`pointycastle` (또는 `cryptography`)** 패키지를 추가합니다. (`pointycastle`은 동기식 블록 암호화 및 임의 블록 오프셋 CTR 제어가 직관적이고 대용량 바이트 처리 속도가 빠르므로 **`pointycastle` 권장**)

```yaml
dependencies:
  # 기존 패키지 유지 ...
  dio: ^5.11.1
  flutter_secure_storage: ^11.2.0
  pointycastle: ^3.9.1 # 추가: AES-ECB, AES-CBC, AES-CTR, PBKDF2 지원
```

---

## 3. 생성 및 수정할 파일 구조

### 신규 생성 파일 (4개 핵심 모듈)
1. `lib/utils/mega_crypto_utils.dart`
   - MEGA 키 파생(v1 StringHash / v2 PBKDF2), Base64URL 코덱, 32바이트 파일 키 XOR 언패킹, 메타데이터(`a`) AES-CBC 복호화, 파일 바이너리 AES-CTR 복호화 유틸리티
2. `lib/services/mega_api_client.dart`
   - `MegaAuthManager` (로그인, `sid` 및 마스터 키 보안 저장소 관리) + `MegaApiClient` (`action: 'us0'`, `'us'`, `'f'`, `'g'` 통신 및 노드 트리 파싱)
3. `lib/services/mega_storage_provider.dart`
   - `CloudService` 상속 및 `CloudStorageProvider` 인터페이스 구현체 (`getFileList`, `getDecryptedFileBytes`, `downloadBytes` 오버라이드 포함)
4. `lib/ui/widgets/comic_page_mega_image.dart`
   - `getDecryptedFileBytes`로 복호화된 `Uint8List`를 받아 `LruMemoryCache`에 캐싱하고 `Image.memory`로 렌더링하는 전용 위젯

### 기존 파일 연동 수정 (5개 파일)
1. `lib/models/cloud_account.dart`: `CloudType` enum에 `mega` 추가
2. `lib/services/account_manager.dart`: `case CloudType.mega:` → `MegaStorageProvider` 반환 연결
3. `lib/services/cloud_history_sync_service.dart`: `CloudType.mega`를 JSON 히스토리 파일 업로드 대상에서 제외(또는 별도 처리)
4. `lib/ui/screens/add_account_dialog.dart`: MEGA 이메일/비밀번호 로그인 UI 추가
5. `lib/ui/screens/home_screen.dart`: `_getAccountIconAndColor`에 `case CloudType.mega:` 아이콘/색상 매핑 추가

---

## 4. 모듈별 상세 뼈대 명세 (Skeleton Specifications)

### 4.1. `lib/utils/mega_crypto_utils.dart`

MEGA 고유의 암호화 규격을 캡슐화하는 정적 유틸리티 클래스입니다.

```dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:pointycastle/export.dart';

/// 복호화된 파일 노드 키 구조체 (16바이트 AES 키 + 8바이트 IV/Nonce)
class MegaFileKey {
  final Uint8List aesKey; // 16 bytes (128-bit)
  final Uint8List iv;     // 8 bytes (64-bit nonce for CTR)
  final Uint8List metaMac; // 8 bytes

  const MegaFileKey({
    required this.aesKey,
    required this.iv,
    required this.metaMac,
  });
}

class MegaCryptoUtils {
  MegaCryptoUtils._();

  // ===========================================================================
  // 1. Base64URL 인코딩 / 디코딩 (패딩 '=' 생략 규격 대응)
  // ===========================================================================

  /// MEGA API에서 사용하는 URL-safe Base64 문자열을 Uint8List로 디코딩
  static Uint8List base64UrlDecode(String input) {
    // TODO: '-', '_'를 표준 Base64로 정규화하고, 4의 배수가 되도록 '=' 패딩을 보정한 뒤 base64Url.decode 수행
    throw UnimplementedError();
  }

  /// Uint8List를 패딩 없는 MEGA 규격 Base64URL 문자열로 인코딩
  static String base64UrlEncode(Uint8List bytes) {
    // TODO: base64Url.encode(bytes).replaceAll('=', '') 반환
    throw UnimplementedError();
  }

  // ===========================================================================
  // 2. 비밀번호 키 파생 (Password Key Derivation & User Hash)
  // ===========================================================================

  /// MEGA v1 계정용 비밀번호 키 유도 (prepare_key_pw) 및 이메일 해시(uh) 생성
  static Uint8List derivePasswordKeyV1(String password) {
    // TODO: 초기 키 [0x93C467E3, 0x7DB0C7A4, 0xD1BE3F81, 0x0152CB56]를
    // 65536 라운드 동안 비밀번호 16바이트 청크 단위로 AES-128-ECB 반복 암호화
    throw UnimplementedError();
  }

  static String calculateUserHashV1(String email, Uint8List passwordKey) {
    // TODO: 소문자 이메일 바이트를 16바이트 단위로 XOR 누적 후 AES-128-ECB를 16384회 수행하여
    // 앞 4바이트 + 8~12바이트(총 8바이트)를 base64UrlEncode로 반환
    throw UnimplementedError();
  }

  /// MEGA v2 계정용 PBKDF2-HMAC-SHA512 키 유도 (100,000 iterations, 32 bytes 출력)
  /// - 앞 16바이트: 마스터 키 복호화용 AES 키
  /// - 뒤 16바이트: 로그인 인증용 User Hash (`uh`)
  static ({Uint8List derivedKey, String userHash}) derivePasswordKeyV2(
    String password,
    String base64Salt,
  ) {
    // TODO: PBKDF2KeyDerivator(HMac(SHA512Digest(), 128))
    // salt = base64UrlDecode(base64Salt), iterations = 100000, desiredKeyLength = 32
    // derivedKey = output.sublist(0, 16)
    // userHash = base64UrlEncode(output.sublist(16, 32))
    throw UnimplementedError();
  }

  // ===========================================================================
  // 3. 마스터 키 및 노드 키 복호화 (AES-128-ECB)
  // ===========================================================================

  /// 단일/다중 16바이트 블록을 AES-128-ECB로 복호화
  static Uint8List decryptAes128Ecb(Uint8List cipherBytes, Uint8List key16) {
    // TODO: ECBBlockCipher(AESEngine())..init(false, KeyParameter(key16))로 16바이트 블록 단위 복호화
    throw UnimplementedError();
  }

  /// 암호화된 마스터 키(`k`)를 파생된 비밀번호 키(`derivedKey`)로 복호화
  static Uint8List decryptMasterKey(String encryptedMasterKeyBase64, Uint8List derivedKey) {
    // TODO: decryptAes128Ecb(base64UrlDecode(encryptedMasterKeyBase64), derivedKey)
    throw UnimplementedError();
  }

  /// 노드의 암호화된 키(`encryptedKeyBase64`)를 마스터 키로 복호화하고,
  /// 파일 노드(32바이트)인 경우 XOR 언패킹하여 16바이트 AES 키와 8바이트 IV 추출
  /// 폴더 노드(16바이트)인 경우 그대로 16바이트 AES 키로 사용
  static MegaFileKey decryptAndUnpackNodeKey(
    String encryptedKeyBase64,
    Uint8List masterKey, {
    required bool isFolder,
  }) {
    // TODO:
    // 1. rawKey = decryptAes128Ecb(base64UrlDecode(encryptedKeyBase64), masterKey)
    // 2. isFolder == true (또는 rawKey.length == 16):
    //    aesKey = rawKey (16B), iv = Uint8List(8), metaMac = Uint8List(8)
    // 3. isFolder == false (rawKey.length == 32):
    //    MEGA 파일 키는 32바이트(8개의 32-bit 워드)로 구성됨:
    //    aesKey[i] = rawKey[i] ^ rawKey[i + 16] (i = 0..15)
    //    iv = rawKey.sublist(16, 24) (8 bytes)
    //    metaMac = rawKey.sublist(24, 32) (8 bytes)
    throw UnimplementedError();
  }

  // ===========================================================================
  // 4. 파일/폴더 메타데이터(`a`) 복호화 (AES-128-CBC, Zero IV)
  // ===========================================================================

  /// 암호화된 속성(`a` 필드)을 복호화하여 JSON Map 반환 (예: `{"n": "만화책 01권.zip"}`)
  static Map<String, dynamic>? decryptNodeAttributes(
    String encryptedAttributesBase64,
    Uint8List nodeAesKey16,
  ) {
    // TODO:
    // 1. cipherBytes = base64UrlDecode(encryptedAttributesBase64)
    // 2. CBCBlockCipher(AESEngine())..init(false, ParametersWithIV(KeyParameter(nodeAesKey16), Uint8List(16)))
    // 3. 복호화된 바이트에서 zero-padding(0x00) 제거 후 UTF-8 디코딩
    // 4. 'MEGA{' 접두사 확인 후 'MEGA' 뒤의 JSON 문자열을 jsonDecode하여 Map 반환
    throw UnimplementedError();
  }

  // ===========================================================================
  // 5. 파일 바이너리 복호화 (AES-128-CTR)
  // ===========================================================================

  /// 다운로드한 암호화 파일 바이너리를 해당 파일의 고유 AES 키(16B)와 IV/Nonce(8B)로 복호화
  /// - initialCounter:8바이트 IV(상위 64비트) + 8바이트 블록 카운터(하위 64비트, Big-Endian, 기본값 0)
  static Uint8List decryptFileBytesCtr({
    required Uint8List encryptedBytes,
    required Uint8List fileAesKey16,
    required Uint8List fileIv8,
    int initialBlockOffset = 0,
  }) {
    // TODO:
    // 1. 16바이트 initialCounter 생성:
    //    counter[0..7] = fileIv8[0..7]
    //    counter[8..15] = initialBlockOffset (64-bit Big-Endian)
    // 2. CTRStreamCipher(AESEngine())..init(false, ParametersWithIV(KeyParameter(fileAesKey16), counter))
    // 3. return streamCipher.process(encryptedBytes)
    // (선택: 대용량 ZIP 파일의 경우 Isolate.run 또는 compute()에서 호출 가능하도록 순수 함수 유지)
    throw UnimplementedError();
  }

  // ===========================================================================
  // 6. RSA 개인키 복호화 및 세션 ID(`csid` -> `sid`) 추출
  // ===========================================================================

  /// 로그인 응답의 `privk`와 `csid`를 복호화하여 43자 세션 ID(`sid`) 반환
  static String decryptSessionId({
    required String encryptedPrivKeyBase64,
    required String encryptedCsidBase64,
    required Uint8List masterKey,
  }) {
    // TODO:
    // 1. privkBytes = decryptAes128Ecb(base64UrlDecode(encryptedPrivKeyBase64), masterKey)
    // 2. MEGA MPI(Multi-Precision Integer) 포맷 파싱: p, q, d, u (BigInt) 추출
    // 3. csid MPI 파싱 후 RSA 복호화: m = c^d mod (p * q) (또는 CRT 가속)
    // 4. 복호화된 바이트의 상위 43바이트를 base64UrlEncode하여 최종 sid 문자열 반환
    throw UnimplementedError();
  }
}
```

---

### 4.2. `lib/services/mega_api_client.dart`

인증(`MegaAuthManager`)과 노드 트리 파싱, 다운로드 URL 발급을 담당하는 클라이언트입니다.

```dart
import 'dart:math';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../utils/mega_crypto_utils.dart';

/// MEGA 세션 및 마스터 키 보안 저장 데이터 모델
class MegaSessionCredentials {
  final String email;
  final String sid;
  final Uint8List masterKey; // 16 bytes
  final String? userHandle;

  const MegaSessionCredentials({
    required this.email,
    required this.sid,
    required this.masterKey,
    this.userHandle,
  });
}

/// 복호화된 MEGA 노드(파일/폴더) 모델
class MegaNodeModel {
  final String handle;     // 'h' (노드 고유 ID)
  final String parentId;   // 'p' (부모 노드 ID)
  final String name;       // 복호화된 'a' -> 'n'
  final int size;          // 's'
  final bool isFolder;     // 't' == 1 (폴더) or 't' >= 2 (루트/휴지통 등), 't' == 0 (파일)
  final int nodeType;      // 0: File, 1: Folder, 2: Cloud Drive Root, 3: Inbox, 4: Rubbish Bin
  final DateTime? modifiedTime; // 'ts' (Unix timestamp)
  final MegaFileKey? decryptedKey; // 파일 바이트 복호화에 사용할 16B AES Key + 8B IV

  const MegaNodeModel({
    required this.handle,
    required this.parentId,
    required this.name,
    required this.size,
    required this.isFolder,
    required this.nodeType,
    this.modifiedTime,
    this.decryptedKey,
  });
}

/// 1. 인증 및 마스터 키 유도/보관 매니저 (`flutter_secure_storage` 연동)
class MegaAuthManager {
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();
  static const String _keyPrefix = 'mega_cred_';

  /// 이메일/비밀번호로 MEGA 로그인 수행 후 세션(`sid`) 및 마스터 키를 유도하고 SecureStorage에 저장
  static Future<MegaSessionCredentials> loginWithEmailAndPassword({
    required String email,
    required String password,
    required String accountId,
    Dio? dio,
  }) async {
    // TODO:
    // 1. Pre-login 요청: POST https://g.api.mega.co.nz/cs?id={seq}
    //    Body: [{"a": "us0", "user": email.trim().toLowerCase()}]
    // 2. 응답의 'v' (버전 1 또는 2) 및 's' (v2 salt) 확인:
    //    - v == 1: MegaCryptoUtils.derivePasswordKeyV1 & calculateUserHashV1
    //    - v == 2: MegaCryptoUtils.derivePasswordKeyV2(password, s)
    // 3. Login 요청: POST https://g.api.mega.co.nz/cs?id={seq}
    //    Body: [{"a": "us", "user": email.trim().toLowerCase(), "uh": userHash}]
    // 4. 응답에서 'k'(암호화된 마스터 키), 'privk'(암호화된 RSA 개인키), 'csid'(암호화된 세션 ID) 추출
    // 5. masterKey = MegaCryptoUtils.decryptMasterKey(k, derivedKey)
    // 6. sid = MegaCryptoUtils.decryptSessionId(encryptedPrivKeyBase64: privk, encryptedCsidBase64: csid, masterKey: masterKey)
    // 7. saveCredentials(accountId, credentials) 호출 후 반환
    throw UnimplementedError();
  }

  /// `flutter_secure_storage`에 `sid`와 `masterKey`(Base64URL) 저장
  static Future<void> saveCredentials(
    String accountId,
    MegaSessionCredentials credentials,
  ) async {
    // TODO: _secureStorage.write(key: '$_keyPrefix${accountId}_sid', value: credentials.sid)
    //       _secureStorage.write(key: '$_keyPrefix${accountId}_mk', value: MegaCryptoUtils.base64UrlEncode(credentials.masterKey))
    throw UnimplementedError();
  }

  /// `flutter_secure_storage`에서 저장된 세션 및 마스터 키 복원
  static Future<MegaSessionCredentials?> loadCredentials(
    String accountId, {
    String email = '',
  }) async {
    // TODO: sid 및 mk를 읽어 MegaSessionCredentials 복원
    throw UnimplementedError();
  }

  /// 계정 연결 해제 시 보안 저장소에서 키 삭제
  static Future<void> deleteCredentials(String accountId) async {
    // TODO: _secureStorage.delete(...)
    throw UnimplementedError();
  }
}

/// 2. MEGA API 클라이언트 (`https://g.api.mega.co.nz/cs`)
class MegaApiClient {
  final Dio _dio;
  String _sid;
  Uint8List _masterKey;
  int _sequenceId = Random().nextInt(0x10000000);

  /// 전체 노드 트리 인메모리 캐시 (MEGA의 `action: 'f'`는 전체 트리를 반환하므로 캐싱하여 폴더 이동 속도 극대화)
  List<MegaNodeModel>? _cachedAllNodes;
  String? _cloudDriveRootHandle; // nodeType == 2 인 루트 폴더 핸들

  static const Set<String> comicExtensions = {
    'zip', 'cbz', 'rar', 'cbr', '7z', 'pdf',
    'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'avif'
  };

  MegaApiClient({
    required String sid,
    required Uint8List masterKey,
    Dio? customDio,
  })  : _sid = sid,
        _masterKey = masterKey,
        _dio = customDio ??
            Dio(BaseOptions(
              baseUrl: 'https://g.api.mega.co.nz',
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 60),
              headers: {'Content-Type': 'application/json'},
            ));

  void updateCredentials({required String sid, required Uint8List masterKey}) {
    _sid = sid;
    _masterKey = masterKey;
  }

  void invalidateNodeCache() {
    _cachedAllNodes = null;
  }

  /// MEGA JSON-RPC 배열 명령 전송 헬퍼 (`POST /cs?id={seq}&sid={sid}`)
  Future<dynamic> _postCommand(Map<String, dynamic> command, {bool includeSid = true}) async {
    // TODO:
    // 1. queryParameters: {'id': (_sequenceId++).toString(), if (includeSid && _sid.isNotEmpty) 'sid': _sid}
    // 2. response = await _dio.post('/cs', queryParameters: ..., data: [command])
    // 3. MEGA 에러 코드 처리 (음수 정수 반환 시: -3 EAGAIN 재시도, -15 ESID 세션 만료 예외 등)
    throw UnimplementedError();
  }

  /// 전체 파일/폴더 트리 요청 (`action: 'f'`) 및 각 노드 키/메타데이터 복호화
  Future<List<MegaNodeModel>> fetchAllNodes({bool forceRefresh = false}) async {
    // TODO:
    // 1. _cachedAllNodes가 있고 !forceRefresh이면 캐시 반환
    // 2. res = await _postCommand({'a': 'f', 'c': 1, 'r': 1})
    // 3. res['f'] 리스트 순회:
    //    - t == 2 인 노드의 'h'를 _cloudDriveRootHandle로 기록
    //    - t == 0 (파일) 또는 t == 1 (폴더)인 노드에 대해:
    //      a) 'k' 필드("userHandle:encryptedKey")에서 ':' 뒤의 encryptedKey 추출
    //      b) MegaCryptoUtils.decryptAndUnpackNodeKey(encryptedKey, _masterKey, isFolder: t != 0)
    //      c) MegaCryptoUtils.decryptNodeAttributes(node['a'], fileKey.aesKey) -> name = attr['n']
    //      d) 만화 지원 확장자 또는 폴더인 경우 MegaNodeModel 생성 후 리스트에 추가
    throw UnimplementedError();
  }

  /// 특정 폴더(`folderId`) 직속 자식 파일/폴더 목록 반환
  /// (`folderId`가 null, 빈 문자열, 또는 `'root'`이면 `_cloudDriveRootHandle` 하위 항목 반환)
  Future<List<MegaNodeModel>> listFiles({String? folderId, bool forceRefresh = false}) async {
    // TODO: fetchAllNodes(forceRefresh: forceRefresh) 호출 후 parentId == targetFolderId 필터링
    throw UnimplementedError();
  }

  /// `fileId`(`handle`)로 캐시된 `MegaNodeModel`(파일 키 및 IV 포함) 조회
  Future<MegaNodeModel?> getNodeById(String fileId) async {
    // TODO: _cachedAllNodes가 없으면 fetchAllNodes() 수행 후 handle == fileId 탐색
    throw UnimplementedError();
  }

  /// 암호화된 파일 다운로드 임시 URL 발급 (`action: 'g'`)
  Future<({String downloadUrl, int size})> getEncryptedDownloadUrl(String fileId) async {
    // TODO:
    // res = await _postCommand({'a': 'g', 'g': 1, 'n': fileId})
    // return (downloadUrl: res['g'] as String, size: (res['s'] ?? 0) as int)
    throw UnimplementedError();
  }

  /// 암호화된 바이너리 다운로드 (Dio 스트림/바이트 수신)
  Future<Uint8List> downloadEncryptedBytes(
    String downloadUrl, {
    void Function(int received, int total)? onProgress,
  }) async {
    // TODO: _dio.get<List<int>>(downloadUrl, options: Options(responseType: ResponseType.bytes), onReceiveProgress: onProgress)
    throw UnimplementedError();
  }
}
```

---

### 4.3. `lib/services/mega_storage_provider.dart`

기존 프로젝트의 `CloudService`(`lib/services/cloud_service_interface.dart`)와 `CloudStorageProvider`(`lib/services/naver_storage_provider.dart`)를 동시에 구현하여, 만화 뷰어 전체 시스템(`BrowserScreen`, `ComicViewerScreen`, `ComicCacheManager`)과 완벽히 호환되도록 구성합니다.

```dart
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import '../models/cloud_account.dart';
import '../models/media_item.dart';
import '../utils/mega_crypto_utils.dart';
import 'cloud_service_interface.dart';
import 'mega_api_client.dart';
import 'naver_storage_provider.dart'; // CloudStorageProvider, CloudFile 정의 포함

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
    // TODO:
    // 1. _apiClient가 이미 있으면 반환
    // 2. MegaAuthManager.loadCredentials(account.id) 조회
    // 3. (폴백) 만약 SecureStorage에 없다면 account.accessToken(sid) 및 account.refreshToken(base64MasterKey)에서 복원
    // 4. _apiClient = MegaApiClient(sid: sid, masterKey: masterKey) 생성 후 반환
    throw UnimplementedError();
  }

  @override
  Future<bool> refreshTokensIfNeeded() async {
    // TODO: _ensureClient()가 정상 초기화되는지 확인
    throw UnimplementedError();
  }

  @override
  Future<Map<String, String>> getStreamHeaders() async {
    // MEGA 임시 다운로드 URL('g')은 별도 인증 헤더가 필요 없음
    return const {};
  }

  // ===========================================================================
  // CloudStorageProvider 인터페이스 구현
  // ===========================================================================

  @override
  Future<List<CloudFile>> getFileList({String? path, String? folderId}) async {
    // TODO:
    // 1. client = await _ensureClient()
    // 2. nodes = await client.listFiles(folderId: folderId ?? path)
    // 3. nodes를 CloudFile 리스트로 매핑하여 반환
    throw UnimplementedError();
  }

  @override
  Future<String> getDownloadUrl(String fileId) async {
    // TODO:
    // 1. _downloadUrlCache 확인 후 유효하면 반환
    // 2. client = await _ensureClient()
    // 3. res = await client.getEncryptedDownloadUrl(fileId)
    // 4. 캐시 저장 후 res.downloadUrl 반환
    throw UnimplementedError();
  }

  @override
  Future<Uint8List> getThumbnail(String fileId) async {
    // TODO: 이미지 파일인 경우 getDecryptedFileBytes(fileId) 호출 (또는 MEGA 'fa' 썸네일 속성 복호화)
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
    // TODO:
    // 1. client = await _ensureClient()
    // 2. node = await client.getNodeById(fileId)
    //    if (node == null || node.decryptedKey == null) throw Exception('파일 복호화 키를 찾을 수 없습니다.');
    // 3. downloadUrl = await getDownloadUrl(fileId)
    // 4. encryptedBytes = await client.downloadEncryptedBytes(downloadUrl, onProgress: onProgress)
    // 5. 백그라운드 Isolate(compute) 또는 동기 호출로 AES-128-CTR 복호화 수행:
    //    return await compute(_decryptIsolateEntry, (
    //      encryptedBytes: encryptedBytes,
    //      aesKey: node.decryptedKey!.aesKey,
    //      iv: node.decryptedKey!.iv,
    //    ));
    throw UnimplementedError();
  }

  // ===========================================================================
  // CloudService 인터페이스 연동 (ComicViewerScreen & ComicCacheManager 호환)
  // ===========================================================================

  @override
  Future<List<MediaItem>> listItems({String? folderId}) async {
    final files = await getFileList(folderId: folderId);
    return files.map((f) => f.toMediaItem()).toList();
  }

  @override
  Future<String> getStreamUrl(MediaItem item) async {
    // 주의: MEGA의 다운로드 URL은 암호화된 스트림을 내려주므로,
    // ZipStreamReader가 평문 ZIP 헤더를 읽으려 할 때 실패하고 자동으로 downloadBytes() 폴백으로 넘어갑니다.
    // 즉시 복호화 다운로드를 유도하기 위해 UnsupportedError를 던지거나 getDownloadUrl(item.id)를 반환합니다.
    throw UnsupportedError('MEGA E2EE 파일은 downloadBytes(AES-CTR 복호화) 파이프라인을 사용합니다.');
  }

  @override
  void invalidateStreamUrl(MediaItem item) {
    _downloadUrlCache.remove(item.id);
  }

  /// ComicCacheManager 및 ComicViewerScreen이 파일/이미지를 로드할 때 호출하는 메서드.
  /// 반드시 복호화가 완료된 평문 Uint8List를 반환해야 ZIP 압축 해제 및 이미지 렌더링이 동작합니다!
  @override
  Future<Uint8List> downloadBytes(
    MediaItem item, {
    void Function(int received, int total)? onProgress,
  }) async {
    return getDecryptedFileBytes(item.id, onProgress: onProgress);
  }
}
```

---

### 4.4. `lib/ui/widgets/comic_page_mega_image.dart`

복호화된 `Uint8List`를 받아 인메모리 캐시(LRU)를 적용하고 화면에 렌더링하는 위젯입니다.

```dart
import 'dart:collection';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../services/mega_storage_provider.dart';

/// 복호화된 MEGA 만화 페이지 이미지를 메모리에 캐싱하는 간단한 LRU 캐시
class MegaImageMemoryCache {
  static final MegaImageMemoryCache instance = MegaImageMemoryCache._();
  MegaImageMemoryCache._();

  final int maxEntries = 30; // 최대 30페이지 캐싱
  final LinkedHashMap<String, Uint8List> _cache = LinkedHashMap<String, Uint8List>();

  Uint8List? get(String key) {
    final value = _cache.remove(key);
    if (value != null) {
      _cache[key] = value; // 최근 사용으로 갱신
    }
    return value;
  }

  void put(String key, Uint8List bytes) {
    if (_cache.containsKey(key)) {
      _cache.remove(key);
    } else if (_cache.length >= maxEntries) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = bytes;
  }

  void clear() => _cache.clear();
}

/// MEGA 클라우드에서 개별 이미지 파일을 다운로드 + AES-128-CTR 복호화 후 렌더링하는 위젯
class ComicPageMegaImage extends StatefulWidget {
  final MegaStorageProvider provider;
  final String fileId;
  final BoxFit fit;
  final Widget? placeholder;
  final Widget? errorWidget;

  const ComicPageMegaImage({
    super.key,
    required this.provider,
    required this.fileId,
    this.fit = BoxFit.contain,
    this.placeholder,
    this.errorWidget,
  });

  @override
  State<ComicPageMegaImage> createState() => _ComicPageMegaImageState();
}

class _ComicPageMegaImageState extends State<ComicPageMegaImage> {
  Uint8List? _decryptedBytes;
  bool _isLoading = true;
  Object? _error;
  double _progress = 0.0;

  String get _cacheKey => '${widget.provider.account.id}:${widget.fileId}';

  @override
  void initState() {
    super.initState();
    _loadAndDecryptImage();
  }

  @override
  void didUpdateWidget(covariant ComicPageMegaImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fileId != widget.fileId ||
        oldWidget.provider.account.id != widget.provider.account.id) {
      _loadAndDecryptImage();
    }
  }

  Future<void> _loadAndDecryptImage() async {
    // 1. 메모리 캐시 히트 확인
    final cached = MegaImageMemoryCache.instance.get(_cacheKey);
    if (cached != null) {
      if (mounted) {
        setState(() {
          _decryptedBytes = cached;
          _isLoading = false;
          _error = null;
        });
      }
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
      _progress = 0.0;
    });

    try {
      // 2. MEGA 다운로드 + AES-128-CTR 복호화 수행
      final bytes = await widget.provider.getDecryptedFileBytes(
        widget.fileId,
        onProgress: (received, total) {
          if (total > 0 && mounted) {
            setState(() {
              _progress = (received / total).clamp(0.0, 1.0);
            });
          }
        },
      );

      // 3. 메모리 캐시 저장
      MegaImageMemoryCache.instance.put(_cacheKey, bytes);

      if (mounted) {
        setState(() {
          _decryptedBytes = bytes;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return widget.placeholder ??
          Center(
            child: SizedBox(
              width: 36,
              height: 36,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                value: _progress > 0 ? _progress : null,
              ),
            ),
          );
    }

    if (_error != null || _decryptedBytes == null) {
      return widget.errorWidget ??
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.enhanced_encryption_outlined, size: 40, color: Colors.redAccent),
                const SizedBox(height: 8),
                Text(
                  'MEGA 이미지 복호화/로딩 실패\n($_error)',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: _loadAndDecryptImage,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('다시 시도'),
                ),
              ],
            ),
          );
    }

    return Image.memory(
      _decryptedBytes!,
      fit: widget.fit,
      gaplessPlayback: true,
    );
  }
}
```

---

## 5. 기존 앱과의 통합 체크리스트 (Integration Steps)

다른 모델이 코딩을 진행할 때 아래 5개 파일도 함께 수정해야 앱 UI에서 MEGA 계정 추가 및 열람이 동작합니다.

1. **`lib/models/cloud_account.dart`**
   - `CloudType` 열거형에 `mega` 추가:
     ```dart
     enum CloudType {
       googleDrive,
       oneDrive,
       webDav,
       box,
       dropbox,
       local,
       terabox,
       baidu,
       naver,
       mega, // 추가
     }
     ```
2. **`lib/services/account_manager.dart`**
   - `import 'mega_storage_provider.dart';` 및 `import 'mega_api_client.dart';` 추가
   - `getService(CloudAccount account)` 스위치문에 추가:
     ```dart
     case CloudType.mega:
       return MegaStorageProvider(account, onAccountUpdated: saveAccount);
     ```
   - `removeAccount(String id)` 호출 시 `MegaAuthManager.deleteCredentials(id)` 함께 호출
3. **`lib/services/cloud_history_sync_service.dart`**
   - `cloudAccounts` 필터링에서 `a.type != CloudType.mega` 추가 (MEGA는 E2EE 전용 업로드 파이프라인이 필요하므로 일반 REST 업로드 대상에서 제외)
4. **`lib/ui/screens/add_account_dialog.dart`**
   - 컨트롤러 추가:
     - `_megaNameController` (기본값 `'MEGA Cloud'`)
     - `_megaEmailController`
     - `_megaPasswordController`
   - `_buildServiceSelectionList()`에 MEGA 타일 추가:
     ```dart
     _buildServiceTile(
       type: CloudType.mega,
       title: 'MEGA (메가 클라우드)',
       subtitle: '종단간 암호화(E2EE) 클라우드 만화책/이미지 연동',
       icon: Icons.lock_outline_rounded,
       iconColor: Colors.redAccent,
     ),
     ```
   - `_saveMega()` 구현:
     - `MegaAuthManager.loginWithEmailAndPassword` 호출 → 반환된 `sid`를 `accessToken`에, `base64UrlEncode(masterKey)`를 `refreshToken` 및 `flutter_secure_storage`에 저장 → `MegaStorageProvider(account).getFileList()` 1회 호출로 정상 동작 검증 후 계정 저장.
5. **`lib/ui/screens/home_screen.dart`**
   - `_getAccountIconAndColor(CloudType type)` 스위치문에 추가:
     ```dart
     case CloudType.mega:
       return (Icons.lock_outline_rounded, Colors.redAccent);
     ```

---

## 6. 구현 시 주의사항 (Edge Cases & Pitfalls)

1. **MEGA 32바이트 파일 키 언패킹 엔디안 및 XOR 규칙**:
   - MEGA의 파일 노드 키는 AES-128-ECB로 복호화하면 32바이트(`Uint8List(32)`)가 됩니다.
   - 실제 파일 내용(CTR)과 속성(CBC)을 복호화할 16바이트 AES 키는 `aesKey[i] = rawKey[i] ^ rawKey[i + 16]` (`0 <= i < 16`)으로 계산해야 합니다.
   - CTR 모드의 8바이트 Nonce(IV)는 `rawKey.sublist(16, 24)`입니다.
2. **메타데이터(`a`) 문자열 패딩 처리**:
   - `MEGA{"n":"..."}` 문자열은 16바이트 블록 크기에 맞추기 위해 뒤쪽이 `0x00`(널 바이트)으로 패딩되어 있습니다.
   - UTF-8 디코딩 후 마지막 `}` 위치를 찾아 잘라내거나 `0x00` 바이트를 제거한 뒤 `jsonDecode`를 수행해야 `FormatException`이 발생하지 않습니다.
3. **2FA(이중 인증) 계정 안내**:
   - MEGA 계정에 2FA(OTP)가 활성화된 경우 `us` 요청 시 `mfa` 핀 코드가 요구될 수 있으므로, 에러 응답이 `-26`(`EMFAREQUIRED`)인 경우 사용자에게 안내 메시지를 표시하거나 선택적 OTP 입력란을 제공합니다.
4. **대용량 ZIP 만화책 복호화 시 UI 블로킹 방지**:
   - 50MB~200MB 크기의 만화책 압축 파일을 AES-128-CTR로 복호화할 때는 메인 UI 스레드가 멈추지 않도록 `Isolate.run` 또는 `compute()` 내에서 `MegaCryptoUtils.decryptFileBytesCtr`를 실행하세요.
