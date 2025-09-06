
@echo off
REM Install multicast_vlc_status.lua into VLC's extensions directory

set "SRC=multicast_vlc_status.lua"
set "DST=%APPDATA%\vlc\lua\extensions"

REM Create the destination directory if it doesn't exist
if not exist "%DST%" (
	mkdir "%DST%"
)

REM Copy the Lua extension
copy "%SRC%" "%DST%"

echo Installed %SRC% to %DST%
