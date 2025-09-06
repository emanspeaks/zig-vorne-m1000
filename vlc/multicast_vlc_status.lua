-- multicast_vlc_status.lua
-- VLC Lua extension to broadcast current media filename + playhead via UDP multicast

require("simplexml")  -- VLC bundles some Lua helpers

-- Metadata so VLC knows what to do
function descriptor()
    return {
        title = "Multicast Timecode Broadcaster",
        version = "1.0.1",
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

-- Add menu item to VLC interface
function menu()
    return {"Start Broadcasting", "Stop Broadcasting", "Send Test Message"}
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
    end
end

-- Input listener functions
function input_changed()
    vlc.msg.info("[multicast_time] Input changed - media loaded")
    if not running then
        vlc.msg.info("[multicast_time] Auto-starting due to media load")
        activate()
    end
end

function playing_changed(state)
    vlc.msg.info("[multicast_time] Playback state changed: " .. tostring(state))
    if state == 1 then  -- playing
        vlc.msg.info("[multicast_time] Media started playing")
    elseif state == 0 then  -- stopped/paused
        vlc.msg.info("[multicast_time] Media stopped/paused")
    end
end

-- VLC startup function
function vlc_main()
    vlc.msg.info("[multicast_time] VLC main called - extension loaded")
    -- Don't auto-activate here, wait for user interaction or media events
end

-- Activate when user enables extension
function activate()
    vlc.msg.info("[multicast_time] ACTIVATING EXTENSION...")

    if running then
        vlc.msg.info("[multicast_time] Already running, skipping activation")
        return
    end

    running = true
    vlc.msg.info("[multicast_time] Starting timer with 250ms interval")

    -- Register the timer
    local timer_id = vlc.timer.register(250, push_status)
    if timer_id then
        vlc.msg.info("[multicast_time] Timer registered successfully (ID: " .. tostring(timer_id) .. ")")
    else
        vlc.msg.err("[multicast_time] Failed to register timer!")
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
    running = false
end

-- Manual test function (can be called from VLC Lua console)
function test_multicast()
    vlc.msg.info("[multicast_time] MANUAL TEST: Creating test message...")
    local test_payload = '{"test":"manual_test","time":12345,"length":67890,"state":"playing"}'
    local result = vlc.net.sendto(test_payload, mcast_addr, mcast_port)
    if result then
        vlc.msg.info("[multicast_time] MANUAL TEST: Sent successfully: " .. test_payload)
    else
        vlc.msg.err("[multicast_time] MANUAL TEST: Failed to send!")
    end
    return result
end

function push_status()
    if not running then
        vlc.msg.dbg("[multicast_time] Not running, skipping")
        return
    end

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

    -- Send directly to multicast address (don't connect first)
    local result = vlc.net.sendto(payload, mcast_addr, mcast_port)
    if result then
        vlc.msg.info("[multicast_time] Sent successfully: " .. payload)
    else
        vlc.msg.err("[multicast_time] Failed to send message!")
    end
end
