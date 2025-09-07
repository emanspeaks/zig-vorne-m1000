@echo off
REM VLC Status Broadcaster Launcher - System VLC Mode
REM Starts the VLC Status Server using system-installed VLC DLLs

REM Default settings
set "DEBUG=0"

REM Check for debug flag in command line arguments
if /I "%~1"=="debug" set "DEBUG=1"

echo VLC Status Broadcaster Launcher - System VLC Mode
echo ==================================================
echo Uses system-installed VLC DLLs via PATH
echo Multicast: 239.255.0.100:8888
echo ==================================================
echo.

REM Check if server executable exists
set "SERVER_EXE=server\build\bin\vlc_status_server.exe"
if not exist "%SERVER_EXE%" (
    echo ERROR: vlc_status_server.exe not found
    echo Please build the server first:
    echo   cd server
    echo   cmake --preset windows-x64
    echo   cmake --build build
    pause
    exit /b 1
)

REM Check if VLC is installed in system (check common locations)
set "VLC_FOUND=0"
set "VLC_PATH="

REM Check common VLC installation paths
if exist "C:\Program Files\VideoLAN\VLC\vlc.exe" (
    set "VLC_PATH=C:\Program Files\VideoLAN\VLC"
    set "VLC_FOUND=1"
) else if exist "C:\Program Files (x86)\VideoLAN\VLC\vlc.exe" (
    set "VLC_PATH=C:\Program Files (x86)\VideoLAN\VLC"
    set "VLC_FOUND=1"
)

REM If not found in common paths, check if vlc.exe is in PATH
if "%VLC_FOUND%"=="0" (
    where vlc.exe >nul 2>&1
    if !errorlevel!==0 (
        echo VLC found in system PATH
        set "VLC_FOUND=1"
    )
)

if "%VLC_FOUND%"=="0" (
    echo ERROR: VLC not found on system
    echo Please install VLC or use the bundled DLL version instead
    echo Try running: start_vlc_status.bat
    pause
    exit /b 1
)

if not "%VLC_PATH%"=="" (
    echo Found VLC installation: %VLC_PATH%
    echo Adding VLC directory to PATH for this session...
    set "PATH=%VLC_PATH%;%PATH%"
) else (
    echo Using VLC from system PATH
)

echo Found server executable: %SERVER_EXE%
echo Using system VLC DLLs
echo.

echo Starting VLC Status Server with system VLC...
if "%DEBUG%"=="1" (
    echo Debug mode enabled: passing --debug to server
    "%SERVER_EXE%" --debug
) else (
    "%SERVER_EXE%"
)

echo.
echo VLC Status Broadcaster is now running!
echo.
echo - Status server is broadcasting to UDP multicast 239.255.0.100:8888
echo.
echo Press any key to stop the status server...
pause >nul

echo.
echo Stopping VLC Status Server...
taskkill /IM vlc_status_server.exe /F >nul 2>&1

echo.
echo VLC Status Broadcaster stopped.
pause
