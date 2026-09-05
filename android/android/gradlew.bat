@rem Bootstrap-friendly Gradle wrapper for Hongda Starlink Android.
@echo off
setlocal
set DIR=%~dp0
set WRAPPER=%DIR%gradle\wrapper\gradle-wrapper.jar
if not exist "%WRAPPER%" (
  echo [Hongda] Downloading official Gradle 8.13 wrapper bootstrap...
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/gradle/gradle/v8.13.0/gradle/wrapper/gradle-wrapper.jar' -OutFile '%WRAPPER%'"
  if errorlevel 1 exit /b 1
)
java -classpath "%WRAPPER%" org.gradle.wrapper.GradleWrapperMain %*
endlocal
