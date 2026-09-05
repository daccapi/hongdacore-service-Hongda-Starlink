@echo off
cd /d "%~dp0"
echo ============================================================
echo Hongda Android Release Build (reuse existing HongdaCore.aar)
echo Build ID: V1.6.4-R2-Android-CoreBridge-R7-NetworkDnsFix-20260813
echo Root: %CD%
echo ============================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\build-android-release.ps1" -SkipCoreBuild
if errorlevel 1 (
  echo.
  echo [FAILED] Hongda Android release build failed.
  pause
  exit /b 1
)
echo.
echo [OK] Hongda Android release build completed.
pause
