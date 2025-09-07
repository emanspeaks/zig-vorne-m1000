-- multicast_vlc_status.lua
-- VLC Lua extension to broadcast current media filename + playhead via UDP multicast

require("simplexml")  -- VLC bundles some Lua helpers

-- Metadata so VLC knows what to do
function descriptor()
    return {
        title = "Multicast Timecode Broadcaster",
        version = "1.0.2",
        author = "Randy Eckman",
        url = "https://github.com/emanspeaks/zig-vorne-m1000",
        shortdesc = "Broadcasts filename + playhead over multicast",
        description = "Pushes current VLC playback status as UDP multicast JSON",
        capabilities = {"input-listener"}  -- Add input listener capability
    }
end

local mcast_addr = "239.255.0.1"
local mcast_port = 5005
local running = false
local last_send = 0
local callback_id = nil
local stream = nil

-- Callback for time changes
local function time_changed()
    push_status()
end

-- Add menu item to VLC interface
function menu()
    return {"Start Broadcasting", "Stop Broadcasting", "Send Test Message", "Send Current Status"}
end

-- Handle menu selections
function trigger_menu(id)
    if id == 1 then
        vlc.msg.info("[multicast_time] Manual start requested")
        if not running then
            activate()
        end
    elseif id == 2 then
        vlc.msg.info("[multicast_time] Manual stop requested")
        deactivate()
    elseif id == 3 then
        vlc.msg.info("[multicast_time] Manual test requested")
        test_multicast()
    elseif id == 4 then
        vlc.msg.info("[multicast_time] Manual status requested")
        push_status()
    end
end

-- Activate when user enables extension
function activate()
    vlc.msg.info("[multicast_time] ACTIVATING EXTENSION...")

    if running then
        vlc.msg.info("[multicast_time] Already running, skipping activation")
        return
    end

    running = true
    -- Create UDP stream for multicast
    local success, result = pcall(function() return vlc.stream("udp://@" .. mcast_addr .. ":" .. mcast_port) end)
    if success and result then
        stream = result
        vlc.msg.info("[multicast_time] UDP stream created successfully")
    else
        vlc.msg.err("[multicast_time] Failed to create UDP stream: " .. tostring(result))
        running = false
        return
    end
    vlc.msg.info("[multicast_time] Extension activated successfully!")

    -- Send an initial test message
    test_multicast()
end

-- Deactivate on exit
function deactivate()
    vlc.msg.info("[multicast_time] Deactivated")
    if callback_id then
        vlc.var.del_callback(callback_id)
        callback_id = nil
    end
    if stream then
        stream:close()
        stream = nil
    end
    running = false
end

-- Input listener functions
function input_changed()
    vlc.msg.info("[multicast_time] Input changed - media loaded")
    if not running then
        vlc.msg.info("[multicast_time] Auto-starting due to media load")
        running = true
    end
    -- Remove previous callback if exists
    if callback_id then
        vlc.var.del_callback(callback_id)
        callback_id = nil
    end
    -- Add callback for time changes
    local input = vlc.object.input()
    if input then
        callback_id = vlc.var.add_callback(input, "time", time_changed)
        vlc.msg.info("[multicast_time] Added time callback")
    end
    push_status()
end

function playing_changed(state)
    vlc.msg.info("[multicast_time] Playback state changed: " .. tostring(state))
    if state == 1 then  -- playing
        vlc.msg.info("[multicast_time] Media started playing")
    elseif state == 0 then  -- stopped/paused
        vlc.msg.info("[multicast_time] Media stopped/paused")
    end
    push_status()
end

-- VLC startup function
function vlc_main()
    vlc.msg.info("[multicast_time] VLC main called - extension loaded")
    -- Don't auto-activate here, wait for user interaction or media events
end

-- Manual test function (can be called from VLC Lua console)
function test_multicast()
    vlc.msg.info("[multicast_time] MANUAL TEST: Creating test message...")
    local test_payload = '{"test":"manual_test","time":12345,"length":67890,"state":"playing"}'
    if stream then
        local success, result = pcall(function() return stream:write(test_payload .. "\n") end)
        if success and result then
            vlc.msg.info("[multicast_time] MANUAL TEST: Sent successfully: " .. test_payload)
        else
            vlc.msg.err("[multicast_time] MANUAL TEST: Failed to send: " .. tostring(result))
        end
    else
        vlc.msg.err("[multicast_time] MANUAL TEST: No stream available!")
    end
    return result
end

function push_status()
    if not running then
        vlc.msg.dbg("[multicast_time] Not running, skipping")
        return
    end

    local now = vlc.misc.mdate()
    if now - last_send < 1000000 then  -- 1 second in microseconds
        return
    end
    last_send = now

    vlc.msg.dbg("[multicast_time] push_status() called")

    local item = vlc.input.item()
    if not item then
        vlc.msg.dbg("[multicast_time] No input item")
        return
    end

    vlc.msg.dbg("[multicast_time] Got input item")

    local meta = item:metas()
    local name = meta["filename"] or meta["title"] or "unknown"
    local input = vlc.object.input()
    if not input then
        vlc.msg.dbg("[multicast_time] No input object")
        return
    end

    vlc.msg.dbg("[multicast_time] Got input object")

    local time = vlc.var.get(input, "time")
    local length = vlc.var.get(input, "length")
    local state = vlc.var.get(input, "state")

    vlc.msg.dbg(string.format("[multicast_time] time=%s, length=%s, state=%s",
        tostring(time), tostring(length), tostring(state)))

    local payload = string.format(
        '{"filename":"%s","time":%d,"length":%d,"state":"%s"}',
        name, time or 0, length or 0, state or "unknown"
    )

    vlc.msg.dbg("[multicast_time] Sending payload: " .. payload)

    -- Send via UDP stream
    if stream then
        local success, result = pcall(function() return stream:write(payload .. "\n") end)
        if success and result then
            vlc.msg.info("[multicast_time] Sent successfully: " .. payload)
        else
            vlc.msg.err("[multicast_time] Failed to send message: " .. tostring(result))
        end
    else
        vlc.msg.err("[multicast_time] No stream available!")
    end
end
