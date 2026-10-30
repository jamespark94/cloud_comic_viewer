# Google 로그인 성공 후 `Exception: 구글 토큰 발급 실패` 원인 및 점검 가이드

브라우저에서 Google 계정 로그인과 권한 동의가 **성공(✓ 인증이 성공적으로 완료되었습니다!)**으로 표시되었음에도 앱으로 돌아온 직후 `Exception: 구글 토큰 발급 실패`가 발생하는 원인과 점검해야 할 코드 위치를 정리한 문서입니다.

---

## 1. 에러가 발생하는 정확한 코드 위치

에러 메시지는 아래 파일의 `OAuthHelper.exchangeGoogleToken()` 메서드에서 발생합니다:

- **만화 뷰어**: [`lib/services/oauth_helper.dart`](file:///D:/My%20Documents/AI/cloud_comic_viewer/lib/services/oauth_helper.dart#L273-L301) (295~297행)
- **미디어 플레이어**: [`lib/services/oauth_helper.dart`](file:///D:/My%20Documents/AI/cloud_media_player/lib/services/oauth_helper.dart#L276-L304) (298~300행)

```dart
final res = await postWithRetry(
  Uri.parse('https://oauth2.googleapis.com/token'),
  headers: {'Content-Type': 'application/x-www-form-urlencoded'},
  body: body,
);

if (res.statusCode != 200) {
  throw Exception('구글 토큰 발급 실패 (${res.statusCode}): ${res.body}');
}
```

즉, **1단계(인가 코드 `code` 발급 및 로컬 루프백 서버 수신)는 성공**했으나, **2단계(받은 `code`를 `https://oauth2.googleapis.com/token`에 보내 Access Token으로 교환하는 과정)**에서 실패한 것입니다.

---

## 2. 왜 브라우저 로그인은 성공했는데 토큰 발급에서 실패하는가? (핵심 원인 3가지)

### 원인 A: 클립보드 자동 감지(`_checkClipboardForAuthCode`)가 이전의 만료된 `code=`를 먼저 제출함 (`400 invalid_grant`) — **[가장 유력]**
Google OAuth의 인가 코드(`authorization_code`)는 **단 1회만 사용 가능한 일회성(One-time) 코드**이며, 요청 시 생성된 `code_verifier`(PKCE)와 1:1로 짝이 맞아야 합니다.

현재 [`add_account_dialog.dart`](file:///D:/My%20Documents/AI/cloud_comic_viewer/lib/ui/screens/add_account_dialog.dart)의 흐름을 보면 다음 현상이 일어납니다:

1. 이전에 테스트하면서 휴대폰 클립보드에 복사해 두었던 `http://localhost:8999/callback?code=...` 주소가 클립보드에 그대로 남아 있습니다.
2. 새 로그인을 위해 브라우저가 열렸다가 닫히며 앱이 포그라운드로 돌아오는 순간(`AppLifecycleState.resumed`), [`didChangeAppLifecycleState`](file:///D:/My%20Documents/AI/cloud_comic_viewer/lib/ui/screens/add_account_dialog.dart#L73-L92)의 `_checkClipboardForAuthCode()`가 작동합니다.
3. 이때 **클립보드에 남아 있던 옛날 `code`**가 `OAuthHelper.submitManualCallback(text)`을 통해 루프백 완료기(`_activeAuthCompleter`)에 채워지거나, 루프백과 경합을 일으킵니다.
4. 그 결과 `exchangeGoogleToken()`이 **이미 만료되었거나 `code_verifier`가 다른 옛날 `code`**로 토큰 발급을 요청하게 되어, Google 서버가 `400 Bad Request (invalid_grant)`를 반환하며 `구글 토큰 발급 실패`가 뜹니다.

#### 점검할 위치:
- [`lib/ui/screens/add_account_dialog.dart`](file:///D:/My%20Documents/AI/cloud_comic_viewer/lib/ui/screens/add_account_dialog.dart#L73-L92)의 `didChangeAppLifecycleState` 및 `_checkClipboardForAuthCode()`
  - OAuth 시작 시(`_startOAuth`) 클립보드를 초기화하거나, 루프백 자동 수신이 이미 성공 중일 때는 클립보드 자동 주입이 개입하지 않도록 해야 합니다.

---

### 원인 B: 네이티브 로그인(`GoogleLoginButton`)과 브라우저 OAuth(`_startOAuth`)의 중복 실행으로 인한 `code_verifier` 불일치
1. [`add_account_dialog.dart`](file:///D:/My%20Documents/AI/cloud_comic_viewer/lib/ui/screens/add_account_dialog.dart#L1603-L1644)에서 `GoogleLoginButton`의 `onError` 콜백이 `_startOAuth()`를 자동으로 호출하도록 되어 있습니다.
2. 만약 사용자가 버튼을 연속으로 탭했거나 네이티브 로그인 실패 직후 브라우저 로그인 버튼을 함께 눌렀다면 `_authenticateGoogle()`이 중복 실행되면서, 로컬 변수 `codeVerifier`와 싱글턴인 `OAuthHelper._activeAuthCompleter`가 덮어써집니다.
3. 브라우저에서 로그인한 세션의 `code_challenge`와 앱이 들고 있는 `code_verifier`가 달라져 `invalid_grant`가 발생합니다.

#### 점검할 위치:
- [`lib/ui/screens/add_account_dialog.dart`](file:///D:/My%20Documents/AI/cloud_comic_viewer/lib/ui/screens/add_account_dialog.dart#L1628-L1633)의 `onError` 자동 전환 로직
- [`lib/services/oauth_helper.dart`](file:///D:/My%20Documents/AI/cloud_comic_viewer/lib/services/oauth_helper.dart#L10)의 `static Completer<String?>? _activeAuthCompleter;` 정적 변수 공유 구조

---

### 원인 C: 인앱 브라우저 종료 직후 안드로이드 네트워크 복구 지연
1. `OAuthHelper.authenticateWithLoopback()`에서 `code`를 받자마자 `closeInAppWebView()`로 브라우저를 닫고 `OAuthHelper.exchangeGoogleToken()`을 호출합니다.
2. 삼성 One UI 환경에서는 Custom Tab에서 메인 앱 화면으로 전환되는 순간(약 0.5~1초) 네트워크 소켓이 일시 단절되는 경우가 있습니다.

#### 점검할 위치:
- [`lib/ui/screens/add_account_dialog.dart`](file:///D:/My%20Documents/AI/cloud_comic_viewer/lib/ui/screens/add_account_dialog.dart#L241-L249)의 `_authenticateGoogle()` 내 `Future.delayed` 및 토큰 교환 호출부

---

## 3. 한눈에 보는 점검 체크리스트 요약

| 순번 | 의심 원인 | 화면에 표시되는 상세 에러 형태 | 확인해야 할 파일 및 라인 |
| :--- | :--- | :--- | :--- |
| **1순위** | **클립보드에 남아있던 이전 `code=` URL이 앱 복귀 시 자동 제출됨** | `구글 토큰 발급 실패 (400): { "error": "invalid_grant", ... }` | [`add_account_dialog.dart` (73~92행)](file:///D:/My%20Documents/AI/cloud_comic_viewer/lib/ui/screens/add_account_dialog.dart#L73-L92) `_checkClipboardForAuthCode()` |
| **2순위** | **중복 호출로 인한 PKCE `code_verifier` 및 `_activeAuthCompleter` 덮어쓰기** | `구글 토큰 발급 실패 (400): { "error": "invalid_grant" }` | [`add_account_dialog.dart` (1628~1633행)](file:///D:/My%20Documents/AI/cloud_comic_viewer/lib/ui/screens/add_account_dialog.dart#L1628-L1633) 및 [`oauth_helper.dart` (10행)](file:///D:/My%20Documents/AI/cloud_comic_viewer/lib/services/oauth_helper.dart#L10) |
| **3순위** | **GCP 콘솔의 Client ID / Client Secret 설정 문제** | `구글 토큰 발급 실패 (401): { "error": "invalid_client" }` | [`google_drive_service.dart` (11~13행)](file:///D:/My%20Documents/AI/cloud_comic_viewer/lib/services/google_drive_service.dart#L11-L13) |
