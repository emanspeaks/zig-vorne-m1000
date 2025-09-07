@echo off
REM VLC Status Broadcaster Launcher
REM Starts VLC with HTTP interface and the status server

REM Default password (can be overridden by command line argument)
set "PASSWORD=vlcstatus"
set "DEBUG=0"

REM Check if password was provided as command line argument
if "%~1" NEQ "" (
    set "PASSWORD=%~1"
)

REM Check for debug flag in command line arguments
if /I "%~2"=="debug" set "DEBUG=1"
if /I "%~1"=="debug" set "DEBUG=1"

echo VLC Status Broadcaster Launcher
echo ================================
echo Password: %PASSWORD%
echo VLC HTTP: http://127.0.0.1:8080
echo Multicast: 239.255.0.100:8888
echo ================================
echo.

REM Check if VLC executable exists
set "VLC_EXE=C:\Program Files\VideoLAN\VLC\vlc.exe"
if not exist "%VLC_EXE%" (
    echo ERROR: VLC executable not found
    echo Please ensure VLC is installed and set VLC_EXE in this script correctly
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
start "VLC Media Player" "%VLC_EXE%" ^
    --http-password=%PASSWORD%
    @REM --no-http-acl

echo Waiting 3 seconds for VLC to start...
timeout /t 3 /nobreak >nul

echo Starting VLC Status Server...
if "%DEBUG%"=="1" (
    echo Debug mode enabled: passing --debug to server
    start "VLC Status Server" "%SERVER_EXE%" "%PASSWORD%" --debug
) else (
    start "VLC Status Server" "%SERVER_EXE%" "%PASSWORD%"
)

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
