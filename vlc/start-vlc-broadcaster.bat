@echo off
REM VLC Status Broadcaster Launcher
REM Starts VLC with HTTP interface and the status server

REM Default password (can be overridden by command line argument)
set "PASSWORD=vlcstatus"

REM Check if password was provided as command line argument
if "%~1" NEQ "" (
    set "PASSWORD=%~1"
)

echo VLC Status Broadcaster Launcher
echo ================================
echo Password: %PASSWORD%
echo VLC HTTP: http://127.0.0.1:8080
echo Multicast: 239.255.0.100:8888
echo ================================
echo.

REM Check if VLC executable exists
where vlc >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: VLC executable not found in PATH
    echo Please ensure VLC is installed and in your PATH
    pause
    exit /b 1
)

REM Check if server executable exists
set "SERVER_EXE=server\build\bin\vlc_status_server.exe"
if not exist "%SERVER_EXE%" (
    echo ERROR: vlc_status_server.exe not found
    echo Please build the server first or ensure it's in the same directory
    pause
    exit /b 1
)

echo Starting VLC with HTTP interface...
start "VLC Media Player" vlc.exe ^
    --http-host=127.0.0.1 ^
    --http-port=8080 ^
    --http-password=%PASSWORD% ^
    --no-http-acl

echo Waiting 3 seconds for VLC to start...
timeout /t 3 /nobreak >nul

echo Starting VLC Status Server...
start "VLC Status Server" "%SERVER_EXE%" "%PASSWORD%"

echo.
echo VLC Status Broadcaster is now running!
echo.
echo - VLC is running with HTTP interface at http://127.0.0.1:8080
echo - Status server is broadcasting to UDP multicast 239.255.0.100:8888
echo - Use password '%PASSWORD%' to access VLC's web interface
echo.
echo Press any key to stop both VLC and the status server...
pause >nul

echo.
echo Stopping VLC Status Server...
taskkill /IM vlc_status_server.exe /F >nul 2>&1

echo Stopping VLC...
taskkill /IM vlc.exe /F >nul 2>&1

echo.
echo VLC Status Broadcaster stopped.
pause
