@echo off
chcp 65001 > nul
echo ========================================================
echo  Cloud Comic & Ebook Viewer - 릴리스 APK 빌드
echo  (ABI 아키텍처 분할 최적화 빌드)
echo ========================================================
echo.

cd /d "%~dp0"

echo [1/2] 릴리스 APK 빌드 중... (잠시만 기다려 주세요)
call flutter build apk --release --split-per-abi

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo [오류] 빌드에 실패했습니다.
    pause
    exit /b %ERRORLEVEL%
)

echo.
echo ========================================================
echo  [빌드 완료] 생성된 APK 파일 목록 및 용량:
echo ========================================================
powershell -Command "Get-ChildItem -Path 'build\app\outputs\flutter-apk' -Filter 'app-*-release.apk' | Select-Object Name, @{Name='크기(MB)';Expression={[math]::Round($_.Length/1MB, 2)}} | Format-Table -AutoSize"

echo.
echo 최신 갤럭시/스마트폰에는:
echo 👉 app-arm64-v8a-release.apk 파일을 설치하시면 됩니다!
echo.
pause
