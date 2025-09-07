-- VLC Status Broadcaster Extension
-- Monitors VLC playback status and sends it to a server via named pipe

local ext_title = "VLC Status Broadcaster"
local pipe_name = "\\\\.\\pipe\\vlc_status"  -- Windows named pipe
local pipe_handle = nil
local update_timer = nil
local last_status = {}
local is_enabled = false
local server_process = nil
local server_exe_path = nil

-- Descriptor: VLC looks for this to provide meta info about our extension
function descriptor()
    return {
        title = ext_title,
        version = "1.1.0",
        author = "Randy Eckman",
        url = "https://github.com/emanspeaks/zig-vorne-m1000",
        description = "Broadcasts VLC playback status to multicast server via named pipe",
        capabilities = {"input-listener", "meta-listener", "playing-listener"}
    }
end

-- Find the server executable path
function find_server_executable()
    -- Get the directory where this Lua script is located
    local script_path = vlc.misc.homedir() .. "\\AppData\\Roaming\\vlc\\lua\\extensions\\"
    local exe_path = script_path .. "vlc_status_server.exe"

    -- Check if the executable exists by trying to read it
    local file = vlc.io.open(exe_path, "rb")
    if file then
        file:close()
        vlc.msg.info("VLC Status Broadcaster: Found server at " .. exe_path)
        return exe_path
    end

    -- Try alternative path (current directory)
    local alt_path = "vlc_status_server.exe"
    file = vlc.io.open(alt_path, "rb")
    if file then
        file:close()
        vlc.msg.info("VLC Status Broadcaster: Found server at " .. alt_path)
        return alt_path
    end

    vlc.msg.err("VLC Status Broadcaster: Server executable not found")
    vlc.msg.err("  Tried: " .. exe_path)
    vlc.msg.err("  Tried: " .. alt_path)
    return nil
end

-- Start the server process
function start_server()
    if server_process or not server_exe_path then
        return server_process ~= nil
    end

    vlc.msg.info("VLC Status Broadcaster: Starting server at " .. server_exe_path)

    -- Launch the server process using Windows start command
    -- This ensures the process runs independently
    local cmd = 'start "" "' .. server_exe_path .. '"'
    local result = os.execute(cmd)

    if result == 0 or result == true then
        server_process = true  -- Mark as started
        vlc.msg.info("VLC Status Broadcaster: Server started successfully")
        -- Give the server a moment to create the named pipe
        -- Simple delay using a loop since vlc.misc.mwait may not be available
        local start_time = os.time()
        while os.time() - start_time < 1 do
            -- Wait about 1 second for server to start
        end
        return true
    else
        vlc.msg.err("VLC Status Broadcaster: Failed to start server (exit code: " .. tostring(result) .. ")")
        return false
    end
end

-- Stop the server process
function stop_server()
    if not server_process then
        return
    end

    vlc.msg.info("VLC Status Broadcaster: Stopping server")

    -- Use Windows taskkill to stop the server process
    local cmd = 'taskkill /IM vlc_status_server.exe /F >nul 2>&1'
    os.execute(cmd)

    server_process = nil
    vlc.msg.info("VLC Status Broadcaster: Server stopped")
end

-- Serialize status data to JSON-like format
function serialize_status(status)
    local json_parts = {}
    for k, v in pairs(status) do
        local value_str
        if type(v) == "string" then
            value_str = '"' .. v:gsub('"', '\\"') .. '"'
        elseif type(v) == "number" then
            value_str = tostring(v)
        elseif type(v) == "boolean" then
            value_str = v and "true" or "false"
        else
            value_str = '"' .. tostring(v) .. '"'
        end
        table.insert(json_parts, '"' .. k .. '": ' .. value_str)
    end
    return "{" .. table.concat(json_parts, ", ") .. "}"
end

-- Get current VLC status
function get_current_status()
    local status = {
        timestamp = os.time(),
        is_playing = false,
        position = 0.0,
        time = 0,
        duration = -1,
        rate = 1.0,
        title = "",
        artist = "",
        album = "",
        filename = "",
        uri = ""
    }

    -- Check if player is active
    if vlc.player.is_playing() then
        status.is_playing = true

        -- Get position and time information
        status.position = vlc.player.get_position() or 0.0
        status.time = vlc.player.get_time() or 0
        status.rate = vlc.player.get_rate() or 1.0

        -- Get current item information
        local item = vlc.player.item()
        if item then
            status.duration = item:duration() or -1
            status.filename = item:name() or ""
            status.uri = item:uri() or ""

            -- Get metadata
            local metas = item:metas()
            if metas then
                status.title = metas.title or ""
                status.artist = metas.artist or ""
                status.album = metas.album or ""
                if metas.filename then
                    status.filename = metas.filename
                end
            end
        end
    end

    return status
end

-- Send status to pipe
function send_status(status)
    if not pipe_handle then
        return false
    end

    local json_data = serialize_status(status)
    local success = pipe_handle:write(json_data .. "\n")
    if success then
        pipe_handle:flush()
        return true
    end
    return false
end

-- Compare two status objects to detect changes
function status_changed(old_status, new_status)
    local keys_to_check = {"is_playing", "position", "time", "duration", "rate", "title", "artist", "album", "filename", "uri"}

    for _, key in ipairs(keys_to_check) do
        if old_status[key] ~= new_status[key] then
            return true
        end
    end

    -- Check if time has advanced more than 2 seconds (for regular updates during playback)
    if new_status.is_playing and math.abs(new_status.time - old_status.time) > 2000000 then  -- 2 seconds in microseconds
        return true
    end

    return false
end

-- Open named pipe connection
function open_pipe()
    if pipe_handle then
        return true
    end

    -- Ensure server is running before trying to connect
    if not server_process and server_exe_path then
        if not start_server() then
            return false
        end
    end

    -- Try to open the named pipe (Windows)
    pipe_handle = vlc.io.open(pipe_name, "w")
    if pipe_handle then
        vlc.msg.info("VLC Status Broadcaster: Connected to pipe " .. pipe_name)
        return true
    else
        vlc.msg.warn("VLC Status Broadcaster: Failed to open pipe " .. pipe_name)
        return false
    end
end

-- Close pipe connection
function close_pipe()
    if pipe_handle then
        pipe_handle:close()
        pipe_handle = nil
        vlc.msg.info("VLC Status Broadcaster: Closed pipe connection")
    end
end

-- Main update function
function update_status()
    if not is_enabled then
        return
    end

    local current_status = get_current_status()

    -- Send status if it has changed or if this is the first update
    if not last_status or status_changed(last_status, current_status) then
        if open_pipe() then
            if send_status(current_status) then
                vlc.msg.dbg("VLC Status Broadcaster: Status sent - " .. (current_status.is_playing and "Playing" or "Stopped"))
                last_status = current_status
            else
                vlc.msg.warn("VLC Status Broadcaster: Failed to send status")
                close_pipe()  -- Close and retry next time
            end
        end
    end

    -- Schedule next update (every 1 second)
    if is_enabled then
        update_timer = vlc.misc.timer(1000000, update_status)  -- 1 second in microseconds
    end
end

-- Start the broadcaster
function start_broadcaster()
    if is_enabled then
        return
    end

    -- Find the server executable
    server_exe_path = find_server_executable()
    if not server_exe_path then
        vlc.msg.err("VLC Status Broadcaster: Cannot start - server executable not found")
        return
    end

    is_enabled = true
    vlc.msg.info("VLC Status Broadcaster: Started")

    -- Start the server and send initial status
    update_status()
end

-- Stop the broadcaster
function stop_broadcaster()
    if not is_enabled then
        return
    end

    is_enabled = false

    -- Cancel timer
    if update_timer then
        update_timer = nil
    end

    -- Send final stopped status
    local final_status = {
        timestamp = os.time(),
        is_playing = false,
        position = 0.0,
        time = 0,
        duration = -1,
        rate = 1.0,
        title = "",
        artist = "",
        album = "",
        filename = "",
        uri = ""
    }

    if open_pipe() then
        send_status(final_status)
    end

    close_pipe()

    -- Stop the server
    stop_server()

    vlc.msg.info("VLC Status Broadcaster: Stopped")
end

-- Extension lifecycle functions
function activate()
    vlc.msg.info("VLC Status Broadcaster: Extension activated")
    start_broadcaster()
end

function deactivate()
    vlc.msg.info("VLC Status Broadcaster: Extension deactivated")
    stop_broadcaster()
end

-- VLC event callbacks
function input_changed()
    vlc.msg.dbg("VLC Status Broadcaster: Input changed")
    if is_enabled then
        -- Force an immediate status update
        last_status = nil
        update_status()
    end
end

function meta_changed()
    vlc.msg.dbg("VLC Status Broadcaster: Metadata changed")
    if is_enabled then
        -- Force an immediate status update
        last_status = nil
        update_status()
    end
end

function status_changed()
    vlc.msg.dbg("VLC Status Broadcaster: Playback status changed")
    if is_enabled then
        -- Force an immediate status update
        last_status = nil
        update_status()
    end
end
