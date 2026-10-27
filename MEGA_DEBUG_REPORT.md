# MEGA Cloud Storage Integration Debug Report
**Date**: 2026-10-27  
**Target Project**: `D:\My Documents\AI\cloud_comic_viewer`  
**Target Device**: Samsung Galaxy (`R3KL502K7SN`)  

---

## 1. Problem Description (현상)
- MEGA 클라우드 계정 추가 (이메일/비밀번호 로그인)는 정상 통과되어 앱 홈 화면에 계정이 등록됨.
- 그러나 해당 MEGA 계정을 탭하여 파일 탐색기(`browser_screen.dart`)에 진입하면 아무 파일/폴더도 목록에 표시되지 않음 (빈 화면).
- 사용자의 실제 MEGA 계정(웹 크롬 브라우저로 직접 확인 완료)에는 정상적인 파일과 폴더들이 존재하는 상태이며, 2단계 인증(2FA)은 꺼져 있음.

---

## 2. Architecture & File Structure (구조)
- **`lib/utils/mega_crypto_utils.dart`**:
  - `MegaCryptoUtils`: Base64URL 인코딩/디코딩, MEGA PBKDF2/AES 키 파생(v1/v2), AES-128-ECB, 32B Node Key XOR 언패킹, AES-128-CBC 속성 복호화, AES-128-CTR 바이너리 복호화.
- **`lib/services/mega_api_client.dart`**:
  - `MegaAuthManager`: `flutter_secure_storage`에 `mega_sid_<accountId>` 및 `mega_masterKey_<accountId>`를 안전하게 저장/로드.
  - `MegaApiClient`: MEGA API 엔드포인트(`https://g.api.mega.co.nz/cs`)와 JSON-RPC 통신.
    - `fetchAllNodes`: `{'a': 'f', 'c': 1, 'r': 1}` 요청으로 전체 노드 트리 조회.
    - `listFiles`: 특정 `folderId`의 자식 노드 반환.
- **`lib/services/mega_storage_provider.dart`**:
  - `MegaStorageProvider`: `CloudService` 및 `CloudStorageProvider` 구현체.
  - `_ensureClient()`: `MegaAuthManager.loadCredentials`를 통해 `MegaApiClient` 인스턴스 생성.
  - `listItems({String? folderId})`: `getFileList()` 호출 후 `MediaItem` 리스트로 변환하여 `browser_screen.dart`에 제공.
- **`lib/ui/screens/browser_screen.dart`**:
  - `_loadFolder()`에서 `widget.service.listItems(folderId: currentFolderId)`를 호출. 첫 진입 시 `currentFolderId`는 `null`임.

---

## 3. Suspected Root Causes (핵심 원인 분석)

### 원인 후보 1: `_ensureClient()` 인증 정보 로드 실패 또는 예외 silent catch
- `browser_screen.dart`의 `_loadFolder()`는 에러 발생 시 `_errorMessage = e.toString()`을 세팅하지만, UI 구성에 따라 빈 목록처럼 보일 수 있음.
- `MegaStorageProvider._ensureClient()`에서:
  ```dart
  final creds = await MegaAuthManager.loadCredentials(account.id, email: account.email);
  ```
  `account.id`가 저장 당시의 ID와 일치하지 않거나, `flutter_secure_storage`에서 `sid`/`masterKey`를 읽지 못하면 Exception(`MEGA 인증 자격을 찾을 수 없습니다`) 발생.
  - 점검 사항: `add_account_dialog.dart`의 `_saveMega()`에서 `account.id`로 저장한 키 이름과 `loadCredentials` 시 전달되는 `account.id`가 완전히 동일한지 확인.

### 원인 후보 2: MEGA `action: 'f'` API 응답의 `res['f']` 노드 필터링 불일치
- `MegaApiClient.fetchAllNodes()`는 `rawList = res['f']`를 순회함.
- MEGA의 노드 트리 구조:
  - `t == 2`: Cloud Drive Root (`_cloudDriveRootHandle`)
  - `t == 3`: Inbox
  - `t == 4`: Trash Bin
  - `t == 1`: 사용자 일반 폴더
  - `t == 0`: 일반 파일
- `listFiles({String? folderId})` 로직:
  - 첫 진입 시 `folderId == null`.
  - 현재 로직:
    ```dart
    if (targetParent.isEmpty || targetParent == 'root') {
      targetParent = _cloudDriveRootHandle ?? '';
    }
    result = all.where((n) => n.parentId == targetParent && n.handle != targetParent).toList();
    ```
  - **주의**: 유저의 최상위 폴더/파일들의 `p`(parentId)가 `_cloudDriveRootHandle`과 일치하지 않거나, MEGA의 유저 루트 핸들과 다르게 매핑된 경우 `result`가 0개가 됨.
  - 또는 MEGA API 응답에서 `_postCommand` 호출 시 세션 만료/세션 ID 형식 불일치로 `-15` 등의 음수 에러 코드가 반환되어 빈 배열을 반환했을 가능성.

### 원인 후보 3: 노드 복호화(Node Key / Attributes) 실패
- `node['k']`가 비어있거나, 복호화 실패 시 `fileKey`가 null이 됨.
- 복호화 실패 시 `name = '폴더'` / `name = '파일'`로 대체하도록 했으나, 만약 `_cachedAllNodes` 자체가 빈 배열이면 `listFiles`도 0개를 반환함.

---

## 4. Work Completed (현재까지 완료된 조치)
1. **포괄적 키 복호화 및 슬래시 분할 로직 반영**:
   - `kStr.split('/')` 및 `okKeys` 지원 추가.
2. **속성 JSON 추출 안정화**:
   - `MegaCryptoUtils.decryptNodeAttributes`에서 `startIdx = text.indexOf('{')`, `endIdx = text.lastIndexOf('}')` 방식으로 JSON 파싱 내구성 강화.
3. **만화 파일 필터 제한 해제**:
   - 지원 만화 확장자가 아니더라도 모든 파일/폴더가 보이도록 조건 제거.
4. **Android Release 빌드 및 배포 테스트 성공**:
   - 빌드 경로: `D:\My Documents\AI\cloud_comic_viewer\build\app\outputs\flutter-apk\app-release.apk`
   - 임시 경로 복사본: `D:\temp\antigravity\cloud_comic_viewer_release.apk` (55.3MB)
   - 기기(`R3KL502K7SN`) 설치 완료.

---

## 5. Next Steps for Next Model / Developer (다음 디버깅 제안)
1. **화면에 명시적 에러/디버그 텍스트 띄우기**:
   - `browser_screen.dart`의 `_loadFolder()`에서 `items.length` 및 catch된 `e.toString()`을 SnackBar나 화면 텍스트(`Text('Error: $_errorMessage')`)로 직접 띄워 원인(인증 실패 vs 0개 반환 vs API -15 등)을 1초 만에 식별할 것.
2. **`MegaApiClient.fetchAllNodes()`의 raw 응답 확인**:
   - `res`가 실제로 `{'f': [...]}`를 정상 반환하는지, 혹시 `-9` (ENOENT), `-15` (ESID/세션 오류), `-16` (EBLOCKED) 등의 에러 코드가 반환되는지 확인.
   - `rawList` 내 노드들의 `p` (parentId)와 `t` (타입) 값을 출력하여 루트 폴더의 핸들과 자식들의 `parentId`가 어떻게 구성되어 있는지 점검할 것.
3. **`_ensureClient` 인증 키 로드 검증**:
   - `MegaAuthManager.loadCredentials`가 `null`을 반환하고 있는지 여부 체크 (`debugPrint` 또는 fallback 확인).
