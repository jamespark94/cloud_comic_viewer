# 만화뷰어 Google 로그인 무한 로딩 분석 (A90 / iPlay60 mini)

## 1. 결론
두 앱은 **Google 로그인 방식 자체가 다릅니다.**

| 항목 | 미디어플레이어 | 만화뷰어 |
|---|---|---|
| 방식 | `google_sign_in` 네이티브 (Google Play Services 계정 선택창) | 브라우저 OAuth + **localhost 루프백 서버** (`OAuthHelper.authenticateWithLoopback`) |
| 코드 | `lib/services/google_auth_manager.dart`, `lib/widgets/google_login_button.dart` | `lib/ui/screens/add_account_dialog.dart` `_authenticateGoogle()` → `lib/services/oauth_helper.dart` |
| 앱↔브라우저 통신 | 불필요 (시스템 계정 API) | 브라우저가 `http://localhost:8999/callback`으로 redirect → 앱 내 HttpServer가 code 수신 |
| 앱 ID | `com.example.cloud_media_player` | `com.antigravity.comic.cloud_comic_viewer` |

- 미디어플레이어는 브라우저·localhost를 쓰지 않아서 기기 환경과 무관하게 동작합니다.
- 만화뷰어는 브라우저가 앱의 localhost 서버로 되돌아와야 완료되는데, **A90/iPlay60 mini에서는 이 콜백이 앱에 도달하지 못해** 로딩이 끝나지 않습니다. 타임아웃이 5분이라 사실상 "무한 로딩"으로 보입니다.
- S26+에서는 Chrome Custom Tab → localhost 호출이 정상이라 둘 다 됩니다.

## 2. 원인 후보 (가능성 순)
1. **기본 브라우저/Custom Tab 문제**: 저가·중국향 ROM(iPlay, 구형 A90)은 Chrome 미설치·구버전이거나 기본 브라우저가 다른 앱이라 `LaunchMode.inAppBrowserView`가 WebView 등으로 폴백됩니다. 일부는 `localhost` 리다이렉트를 차단하거나 PNA(Private Network Access)로 막습니다. Google 로그인 페이지는 임베디드 WebView를 차단(`disallowed_useragent`)하기도 합니다.
2. **localhost 해석 문제**: redirect는 `localhost`인데 서버는 `127.0.0.1`(IPv4), 선택적으로 `::1` 바인딩입니다. 브라우저가 IPv6 `::1`을 먼저 시도하는데 IPv6 바인딩이 실패한 기기에서는 연결이 실패하거나 지연됩니다.
3. **백그라운드 제한**: 브라우저로 전환되는 동안 앱이 freeze/kill되면 서버가 죽습니다. 코드에 배터리 최적화 제외 요청이 있지만 A90/iPlay의 자체 절전 정책은 우회하지 못할 수 있습니다.
4. **포트 8999 점유/차단**: 이전 시도의 서버가 남아 있거나 다른 앱이 쓰는 경우입니다. 폴백으로 임의 포트를 쓰더라도 Google 웹 클라이언트 유형에 따라 redirect 불일치가 날 수 있습니다.
5. **OAuth 클라이언트 설정**: 현재 `defaultClientId`/`defaultClientSecret`이 코드에 하드코딩된 데스크톱형 클라이언트입니다. 앱 서명 SHA-1은 이 흐름과 무관해서 기기별 차이의 원인은 아닙니다.

> 정확한 원인 확정에는 두 기기에서 `adb logcat`으로 확인이 필요합니다. 브라우저에서 로그인 후 어떤 화면에서 멈추는지(구글 로그인 화면 전/후, "연결할 수 없음" 표시 여부)도 단서가 됩니다.

## 3. 해결 방안

### 방안 A (권장): 미디어플레이어와 동일한 `google_sign_in` 네이티브 로그인 사용
만화뷰어에도 이미 `GoogleAuthManager`, `GoogleLoginButton`, `google_sign_in` 의존성이 있습니다. `GoogleDriveService`도 `refreshToken == 'google_sign_in'`이면 `GoogleAuthManager`를 쓰도록 되어 있습니다.
- `add_account_dialog.dart`의 `_authenticateGoogle()`을 `GoogleAuthManager().signIn()` 기반으로 교체합니다. 성공하면 `CloudAccount(type: googleDrive, refreshToken: 'google_sign_in', email: account.email)`를 저장합니다.
- 브라우저, localhost, 포트, 절전 이슈가 모두 사라집니다.
- **필수 확인**: Google Cloud Console에 Android OAuth 클라이언트를 `com.antigravity.comic.cloud_comic_viewer` + 해당 앱 서명 SHA-1(디버그/릴리스)로 등록해야 합니다. 미디어플레이어(`com.example.cloud_media_player`)용 등록만으로는 만화뷰어가 동작하지 않습니다. 미등록이면 `ApiException: 10` 또는 `12500`이 발생합니다.
- `drive.readonly`는 민감 스코프라 OAuth 동의화면이 테스트 모드이면 테스트 사용자 등록이 필요합니다.

### 방안 B: 루프백 방식 유지 + 보강 (A가 어려울 때)
1. redirect를 `http://127.0.0.1:$port/callback`으로 변경하고 IPv4만 사용합니다. `localhost`의 IPv6 해석 문제를 제거합니다.
2. `launchUrl`을 `LaunchMode.externalApplication`(실제 기본 브라우저) 우선으로 바꾸고 `inAppBrowserView`는 폴백으로 둡니다. WebView 폴백으로 인한 차단을 방지합니다.
3. 이미 있는 **수동 URL/코드 붙여넣기 UI**(`_showManualInput`, `submitManualCallback`)를 일정 시간(예: 15초) 뒤 자동 노출하고, 안내 문구를 보강합니다. 콜백이 실패해도 주소창의 `code=` URL을 붙여넣어 완료할 수 있습니다.
4. 타임아웃을 5분에서 60~90초로 줄이고 실패 원인(포트, 브라우저 실행 실패, 타임아웃)을 에러 메시지로 표시합니다.
5. 포트 8999 고정 대신 `0`으로 바인딩해서 실제 포트를 redirect에 사용합니다. 데스크톱형 클라이언트는 loopback 임의 포트를 허용합니다.

### 방안 C: Device Code Flow
브라우저 redirect 없이 "코드 입력" 방식입니다. Google은 Drive 스코프를 허용하지만 별도 "TV/제한 입력 기기" 클라이언트가 필요하고, UX가 번거롭습니다. 위 방안이 모두 안 될 때의 대안입니다.

## 4. 권장 작업 순서
1. A90에서 `adb logcat | findstr -i "oauth chrome customtabs localhost"`로 멈추는 지점을 확인합니다(5분).
2. 방안 A를 적용합니다. 이를 위해 Cloud Console에 만화뷰어 패키지명/SHA-1 Android 클라이언트를 추가합니다.
3. 기존 사용자 호환을 위해 loopback 계정(`refreshToken` 있음)은 그대로 동작하게 두고, 신규 로그인만 네이티브로 바꿉니다.
4. 방안 B의 1·3번(127.0.0.1 사용, 수동 입력 자동 노출)은 폴백으로 같이 적용하면 좋습니다.

## 5. 참고 (보안)
`google_drive_service.dart`에 `defaultClientSecret`(...)이 소스에 하드코딩되어 있습니다. 저장소가 공개라면 해당 시크릿을 재발급(rotate)하는 것을 권장합니다.
