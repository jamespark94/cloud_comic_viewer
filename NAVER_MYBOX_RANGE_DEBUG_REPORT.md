# 네이버 MYBOX HTTP Range 스트리밍 403 에러 디버깅 리포트

## 1. 이슈 개요
- **증상**: 구글 드라이브, 바이두, 테라박스 등 다른 클라우드에서는 ZIP 파일 스트리밍(HTTP Range 파싱)이 정상 동작하지만, **네이버 MYBOX**에서 ZIP 만화책을 열람할 때 HTTP Range 요청에서 `HTTP 403 Forbidden`이 반환되어 스트리밍 실패 후 전체 다운로드로 폴백되는 현상 발생.
- **최종 에러 로그**:
  ```text
  10-27 09:20:21.072 I flutter : 스트리밍 파싱 실패, 전체 다운로드 폴백: Exception: Range 요청 실패: HTTP 403
  ```
  이후 전체 다운로드 폴백 시에도 `Exception: 파일 다운로드 실패 (403)` 발생.

---

## 2. 관련 파일 및 아키텍처 구조
1. **`lib/services/naver_box_api_client.dart`**
   - 네이버 MYBOX 공식 Open API 클라이언트 (`https://open-api.mybox.naver.com`)
   - `getDownloadUrl(fileId)`: `/v1/drive/files/{fileId}/download` 호출하여 1회용 다운로드 서명 URL (`downloadUrl`) 획득 (유효기간 10분/600초).
2. **`lib/services/naver_storage_provider.dart`**
   - `CloudService` 및 `CloudStorageProvider` 인터페이스 구현체.
   - `getStreamUrl(MediaItem item)`: 파일의 다운로드 URL 반환.
   - `getStreamHeaders()`: 스트리밍 및 파일 다운로드 시 전송할 HTTP 헤더 반환.
3. **`lib/services/zip_stream_reader.dart`**
   - `HttpCloudRangeReader`: 원격 ZIP 파일의 EOCD(End of Central Directory) 및 Central Directory를 읽기 위해 `bytes=$start-$end` 형태의 HTTP Range GET 요청을 수행하는 클래스.
   - `readRange(int start, int end)`:
     ```dart
     final req = http.Request('GET', Uri.parse(_streamUrl!));
     req.headers.addAll(_headers ?? {});
     req.headers['Range'] = 'bytes=$start-$end';
     final streamedRes = await _client.send(req);
     ```

---

## 3. 지금까지 진행된 디버깅 및 시도 내역

### 시도 1: 메타데이터 `fileSize` 우선 사용 및 Range 절대 범위 지정
- **조치**:
  - `getTotalLength()`에서 `item.size`가 존재하면 불필요한 Range(0-0) 요청 없이 메타데이터를 즉시 사용하도록 수정.
  - `readRange()`에서 Range 헤더를 반드시 `bytes=$start-$end` 형태(절대 범위)로 명시.
  - 응답 코드가 200 OK일 경우 전체 파일 다운로드를 막기 위해 스트림 취소(`drain`) 및 에러 발생 처리.

### 시도 2: 302 리다이렉트 사전 해석(Pre-resolve) 및 헤더 추가
- **조치**:
  - 바이두/테라박스와 동일한 패턴으로 `followRedirects = false` 요청을 보내 302 리다이렉트 시 최종 CDN URL을 사전 해석하려 시도.
  - 헤더에 `Referer: https://mybox.naver.com/`, `Origin: https://mybox.naver.com`, `Authorization: Bearer <PAT>` 추가.
- **결과**:
  - `파일 다운로드 실패 (403)` 발생.

### 시도 3: 네이버 서명 URL 충돌 방지를 위한 헤더 최소화
- **조치**:
  - 네이버의 `downloadUrl`은 URL 쿼리 파라미터(`atoken`, `resourceKey`, `auth=3`) 자체에 서명이 포함되어 있으므로, `Authorization`이나 `Referer`를 붙이면 오히려 CDN/스토리지 서버 서명 검증에서 충돌을 일으킨다고 판단.
  - `getStreamHeaders()`에서 `Authorization`과 `Referer/Origin`을 제거하고 `User-Agent`만 남김.
  - 302 사전 해석 로직을 제거하고 발급된 `downloadUrl`을 직접 호출.
- **결과**:
  - 여전히 `Exception: Range 요청 실패: HTTP 403` 발생.

---

## 4. 핵심 발견 사항 및 후속 모델을 위한 디버깅 포인트

1. **Range 헤더 자체에 대한 네이버 스토리지 서버의 차단 가능성**:
   - 네이버 MYBOX Open API가 반환하는 `downloadUrl`의 스토리지 엔드포인트(`https://{storage-domain}/v1/storage/download?auth=3&resourceKey=...&atoken=...`)는 **HTTP `Range` 요청을 지원하지 않거나, 서명 토큰(`atoken`) 생성 시 Range 요청이 허용되지 않아 403을 뱉을 가능성**이 높음.
   - **확인 방법**:
     - curl이나 별도 테스트 스크립트로 `Range` 헤더 없이 GET 요청을 보냈을 때 정상 200 OK가 오는지 확인.
     - 동일 URL에 `Range: bytes=0-100` 헤더를 붙였을 때 403이 발생하는지 직접 테스트.

2. **로그인 방식 차이 (PAT vs Web Cookie)**:
   - 현재 구현은 `open-api.mybox.naver.com`의 개인 액세스 토큰(PAT) 방식을 사용 중.
   - 웹뷰 방식(NID_AUT, NID_SES 쿠키)으로 브라우저 모바일 웹 엔드포인트(`m.mybox.naver.com`)를 직접 호출할 때와 Open API 엔드포인트의 동작 차이 비교 필요.

3. **다운로드 링크 1회성(Single-use) 만료 여부**:
   - `downloadUrl`이 1회 호출 시 즉시 무효화되는 일회성 링크인 경우, `HttpCloudRangeReader`가 Range 요청을 2회 이상 연속(예: EOCD 읽기 -> Central Directory 읽기) 날릴 때 두 번째 요청부터 403이 발생할 수 있음.
   - 매 Range 요청마다 새로운 `downloadUrl`을 발급받아야 하는지 점검 필요.

---

## 5. 최종 해결 완료 (Resolution)
1. **문제의 핵심**:
   - 네이버 MYBOX 다운로드 서명 URL은 일회성 성격을 지니거나 Range 요청 시 403으로 처리됨.
   - 스트리밍 실패 후 전체 다운로드 폴백 단계에서 `NaverStorageProvider`가 이미 소진된 실패 URL을 캐시에서 그대로 재사용하여 `파일 다운로드 실패 (403)`가 발생함.
2. **적용된 해결책**:
   - `CloudService`에 `invalidateStreamUrl(MediaItem item)` 도입.
   - `downloadBytes()` 및 `HttpCloudRangeReader`에서 403/401 발생 시 캐시를 무효화하고 새로운 서명 URL을 발급받아 1회 자동 재시도하는 복구 매커니즘 구현.
   - 스트리밍 실패 시 캐시를 즉시 삭제하여 다운로드 폴백 시 완전한 새 URL로 정상 다운로드 및 압축 해제가 이루어지도록 보장.

