
@echo off
REM Install Lua extension and server binary into VLC's extensions directory

set "LUA_SRC=lua\status_broadcaster.lua"
set "SERVER_SRC=server\build\bin\vlc_status_server.exe"
set "DST=%APPDATA%\vlc\lua\extensions"

REM Create the destination directory if it doesn't exist
if not exist "%DST%" (
	mkdir "%DST%"
)

REM Copy the Lua extension
copy "%LUA_SRC%" "%DST%"
echo Installed %LUA_SRC% to %DST%

REM Copy the server binary
if exist "%SERVER_SRC%" (
    copy "%SERVER_SRC%" "%DST%"
    echo Installed %SERVER_SRC% to %DST%
) else (
    echo Warning: Server binary not found. Please build the server first using:
    echo   cd server ^&^& cmake --preset windows-x64 ^&^& cmake --build --preset windows-x64
)
