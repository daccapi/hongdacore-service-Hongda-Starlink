@echo off
cd /d "%~dp0"
echo ============================================================
echo Hongda Android Core Build
echo Build ID: V1.6.4-R2-Android-CoreBridge-R3-GomobileFix-20260813
echo Root: %CD%
echo ============================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\build-android-core.ps1"
if errorlevel 1 (
  echo.
  echo [FAILED] Hongda Android Core build failed.
  pause
  exit /b 1
)
echo.
echo [OK] Hongda Android Core build completed.
pause
