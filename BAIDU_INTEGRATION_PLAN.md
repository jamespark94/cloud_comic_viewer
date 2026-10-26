# 바이두 넷디스크 (Baidu Netdisk / 百度网盘) 계정 연결 구현 계획서

> **목적**: 세션 초기화(`/clear`) 또는 모델 변경 후에도 즉시 참조하여 코딩을 시작할 수 있도록 작성된 상세 설계 및 구현 명세서입니다.
> **우선 적용 대상**: `D:\My Documents\AI\cloud_comic_viewer` (만화 뷰어 프로젝트)
> **차후 확장 대상**: `D:\My Documents\AI\cloud_media_player` (미디어 플레이어 프로젝트)

---

## 1. 개요 및 핵심 전략

테라박스(`TeraBoxService`)는 바이두 넷디스크 해외판(구 Dubox)에서 출발하여 내부 웹 API 규격과 파일 식별 체계(`fs_id|path`), `jsToken` 인증 방식이 90% 이상 동일합니다.
따라서 기존 `lib/services/terabox_service.dart` 및 `AddAccountDialog`의 쿠키 입력 UX를 그대로 재활용하면서, **바이두 고유의 도메인(`pan.baidu.com`), 쿠키(`BDUSS` / `STOKEN`), 다운로드 User-Agent(`LogStatistic`) 및 PCS API 폴백**만 바이두 규격에 맞게 적용합니다.

### 사용자 확정 요구사항
1. **적용 순서**: 만화 뷰어(`cloud_comic_viewer`)에 먼저 적용한다.
2. **쿠키 입력 UX**: 테라박스와 동일하게 **단일 쿠키 입력창**을 사용한다.
   - 사용자가 `BDUSS` 단독 값만 붙여넣거나, `BDUSS=xxx; STOKEN=yyy; ...` 형태의 전체 Cookie 헤더 문자열을 붙여넣어도 `BaiduService.normalizeBaiduCookie()`가 자동으로 파싱·정규화하여 저장한다.

---

## 2. 테라박스 vs 바이두 기술 스펙 비교

| 항목 | 테라박스 (`TeraBoxService`) | 바이두 넷디스크 (`BaiduService`) |
| :--- | :--- | :--- |
| **기본 도메인** | `https://www.terabox.com` | `https://pan.baidu.com` |
| **Referer 헤더** | `https://www.terabox.com/` | `https://pan.baidu.com/` |
| **App ID** | `250528` | `250528` (동일) |
| **Channel 파라미터** | `channel=dubox` | `channel=chunlei` |
| **핵심 인증 쿠키** | `ndus=...` | `BDUSS=...` (및 선택적 `STOKEN=...` 동시 포함 지원) |
| **jsToken 추출 URL** | `/main` | `https://pan.baidu.com/disk/main`, `https://pan.baidu.com/disk/home` |
| **계정 정보 검증 API** | `/api/user/getinfo` + `/api/list` | `https://pan.baidu.com/rest/2.0/xpan/nas?method=uinfo` + `/api/list` |
| **파일 목록 조회 API** | `/api/list` | `https://pan.baidu.com/api/list` (동일 파라미터) |
| **파일 관리 API** | `/api/filemanager`, `/api/create` | `https://pan.baidu.com/api/filemanager`, `/api/create` (동일) |
| **다운로드/스트리밍 링크** | `/api/filemetas?dlink=1` | 1순위: `d.pcs.baidu.com/rest/2.0/pcs/file?method=locatedownload`<br>2순위: `pan.baidu.com/api/filemetas?dlink=1`<br>3순위: 302 Redirect Pre-resolution |
| **다운로드 User-Agent** | 일반 Chrome 브라우저 UA | **`LogStatistic`** 또는 `pan.baidu.com;netdisk;...` (바이두 CDN 403 방지 필수) |

---

## 3. 수정 및 생성할 파일 목록 (`cloud_comic_viewer`)

### Step 1: `lib/models/cloud_account.dart`
- `CloudType` 열거형에 `baidu` 추가:
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
  }
  ```

### Step 2: `lib/services/baidu_service.dart` (신규 생성)
- `TeraBoxService`(`lib/services/terabox_service.dart`)를 베이스로 작성하되 다음 핵심 로직을 구현:

1. **상수 정의**:
   ```dart
   static const String defaultUserAgent =
       'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
   // 바이두 PCS / dlink 다운로드 전용 User-Agent (403 Forbidden 방지용)
   static const String pcsUserAgent = 'LogStatistic';
   static const String appId = '250528';
   ```

2. **쿠키 정규화 (`normalizeBaiduCookie`)**:
   - 입력값이 전체 쿠키(`BDUSS=xxx; STOKEN=yyy; ...`)인 경우:
     - `BDUSS` 값을 필수로 추출하고, `STOKEN`이나 `BAIDUID`가 함께 있으면 `BDUSS=xxx; STOKEN=yyy` 형태로 조합하여 반환.
   - 입력값이 `BDUSS=xxx` 형태이거나 순수 토큰 문자열(`xxx...`)인 경우:
     - `BDUSS=xxx` 형태로 정규화하여 반환.
   - `cookieHeader` getter:
     - `account.accessToken`에 이미 `BDUSS=`가 포함되어 있으면 그대로 사용하고, 없으면 `'BDUSS=${account.accessToken.trim()}'`을 반환.

3. **`jsToken` 파싱 (`_fetchJsToken`)**:
   - 대상 URL: `https://pan.baidu.com/disk/main`, `https://pan.baidu.com/disk/home`
   - 정규식: 테라박스와 동일하게 `fn%28%22([a-zA-Z0-9_]+)%22%29`, `window.jsToken`, `'jsToken':'...'`, `fn("...")` 모두 지원.
   - 주의: 바이두는 `jsToken` 없이도 `/api/list` 등이 동작하는 경우가 있으므로, 만약 `_fetchJsToken()`이 `null`을 반환하더라도 쿠키(`BDUSS`) 자체가 유효하면 `refreshTokensIfNeeded()`가 `true`를 반환하도록 유연하게 처리.

4. **계정 유효성 검증 (`verifyAccount`)**:
   - 1차: `https://pan.baidu.com/rest/2.0/xpan/nas?method=uinfo` 호출 (`errno == 0` 확인 후 `baidu_name` 또는 `netdisk_name` 추출).
   - 2차(폴백): `https://pan.baidu.com/api/list?app_id=250528&web=1&channel=chunlei&clienttype=0&jsToken=...&dir=%2F&num=1&page=1` 호출하여 `errno == 0`이면 유효한 계정으로 인정.

5. **폴더 및 파일 목록 조회 (`listItems`)**:
   - `https://pan.baidu.com/api/list` (`app_id=250528`, `web=1`, `channel=chunlei`, `clienttype=0`, `jsToken`, `dir`, `num=1000`, `page=1`, `order=name`, `desc=0`)
   - 응답의 `list` 배열을 `MediaItem`으로 매핑 (`id: isDir ? path : '$fsId|$path'`).

6. **만화책 스트리밍/다운로드 URL 획득 (`getStreamUrl` & `getStreamHeaders`)**:
   - `ZipStreamReader`의 HTTP Range 요청(`bytes=start-end`)과 `ComicCacheManager`의 전체 다운로드를 모두 지원해야 함.
   - **1순위 (PCS `locatedownload` API)**:
     - URL: `https://d.pcs.baidu.com/rest/2.0/pcs/file?method=locatedownload&app_id=250528&path=${Uri.encodeComponent(filePath)}&ver=2.0&dtype=1&esl=1`
     - 헤더: `User-Agent: LogStatistic`, `Cookie: $cookieHeader`, `Referer: https://pan.baidu.com/`
     - 응답 JSON 내 `urls` 리스트(`urls[0]['url']`) 또는 `server`+`path`에서 직링크 추출.
   - **2순위 (`/api/filemetas` `dlink` 폴백)**:
     - URL: `https://pan.baidu.com/api/filemetas?app_id=250528&web=1&channel=chunlei&clienttype=0&jsToken=...&fsids=[$fsId]&dlink=1` (주의: 바이두 `fsids`는 숫자 배열 형태 `[$fsId]` 또는 `["$fsId"]` 모두 대응)
     - 획득한 `dlink`에 대해 `followRedirects = false` 및 `User-Agent: LogStatistic`으로 302 Location 헤더를 사전 해석(Pre-resolve)하여 최종 CDN URL 획득.
   - **`getStreamHeaders()`**:
     ```dart
     @override
     Future<Map<String, String>> getStreamHeaders() async {
       return {
         'User-Agent': pcsUserAgent, // 'LogStatistic'
         'Cookie': cookieHeader,
         'Referer': 'https://pan.baidu.com/',
       };
     }
     ```

7. **파일 관리 기능 (`renameItem`, `deleteItem`, `createFolder`, `moveItem`, `copyItem`)**:
   - `https://pan.baidu.com/api/filemanager` (`opera=rename|delete|move|copy`, `channel=chunlei`, `app_id=250528`, `web=1`, `clienttype=0`, `jsToken=...`)
   - `https://pan.baidu.com/api/create` (폴더 생성)
   - 참고: 바이두 `/api/filemanager`는 `async=0` 또는 `onnest=fail` 파라미터를 함께 주면 동기식으로 즉시 결과를 반환함 (`errno == 0`).

### Step 3: `lib/services/account_manager.dart`
- `import 'baidu_service.dart';` 추가.
- `getService(CloudAccount account)` 스위치문에 추가:
  ```dart
  case CloudType.baidu:
    return BaiduService(account, onAccountUpdated: saveAccount);
  ```

### Step 4: `lib/services/cloud_history_sync_service.dart`
- 46행 부근 `cloudAccounts` 필터링 조건에서 `terabox`와 동일하게 `baidu`도 JSON 동기화 파일 업로드 대상에서 제외:
  ```dart
  final cloudAccounts = accountManager.accounts
      .where((a) =>
          a.type != CloudType.local &&
          a.type != CloudType.terabox &&
          a.type != CloudType.baidu)
      .toList();
  ```

### Step 5: `lib/ui/screens/add_account_dialog.dart`
- `import '../../services/baidu_service.dart';` 추가.
- 컨트롤러 추가:
  ```dart
  final TextEditingController _baiduCookieController = TextEditingController();
  final TextEditingController _baiduNameController = TextEditingController(text: 'Baidu Netdisk');
  ```
  (`dispose()`에도 해제 코드 추가)
- `_startOAuth()` 분기문에 추가:
  ```dart
  } else if (_selectedType == CloudType.baidu) {
    await _saveBaidu();
  }
  ```
- `_saveBaidu()` 메서드 구현 (`_saveTeraBox()`와 동일한 구조):
  - `BaiduService.normalizeBaiduCookie(rawCookie)` 호출
  - `BaiduService(tempAccount).verifyAccount()` 검증 후 계정 저장
- `_buildServiceSelectionList()`에 바이두 타일 추가:
  ```dart
  _buildServiceTile(
    type: CloudType.baidu,
    title: 'Baidu Netdisk (바이두)',
    subtitle: '바이두 클라우드 만화책 스트리밍 (BDUSS 쿠키 연결)',
    icon: Icons.cloud_done_outlined,
    iconColor: Colors.blueAccent,
  ),
  ```
- `_buildServiceDetailView()`에 `case CloudType.baidu:` 타이틀/아이콘 매핑 및 쿠키 입력 UI 블록 추가 (`type == CloudType.terabox` 블록 바로 아래에 동일 디자인으로 배치):
  - 안내 문구:
    1. PC 브라우저에서 `pan.baidu.com` 에 로그인합니다.
    2. F12 (개발자 도구) → [Application] → [Cookies] → [`https://pan.baidu.com`] 클릭
    3. 이름 목록 중 **`BDUSS`** 항목의 Value 값을 복사하여 붙여넣습니다. (전체 Cookie 문자열이나 `STOKEN`이 함께 포함된 문자열을 붙여넣어도 자동 추출됩니다)
  - `웹 브라우저로 Baidu 열기` 버튼 (`https://pan.baidu.com/`)
  - 계정 표시 이름 입력란 + `BDUSS 쿠키 값 (필수) *` 입력란 (`maxLines: 2`)

### Step 6: `lib/ui/screens/home_screen.dart` 및 `lib/ui/screens/browser_screen.dart`
- `home_screen.dart`의 `_getAccountIconAndColor(CloudType type)` 스위치문에 추가:
  ```dart
  case CloudType.baidu:
    return (Icons.cloud_done_outlined, Colors.blueAccent);
  ```
- `browser_screen.dart` 등 기타 `CloudType` 분기(있는 경우) 확인하여 아이콘/색상 매핑.

---

## 4. 검증 계획 (코딩 완료 후 수행할 테스트)
1. `flutter analyze` 실행하여 컴파일 에러 및 누락된 enum switch 케이스가 없는지 정적 분석 통과 확인.
2. `flutter test` 실행하여 기존 테스트 통과 확인.
3. 앱 실행 후 `[클라우드 드라이브 연결]` → `[Baidu Netdisk (바이두)]` 선택 시 테라박스와 동일한 쿠키 안내 UI 및 입력 폼이 정상 표시되는지 확인.
