-- multicast_vlc_status.lua
-- VLC Lua extension to broadcast current media filename + playhead via UDP multicast

require("simplexml")  -- VLC bundles some Lua helpers

-- Metadata so VLC knows what to do
function descriptor()
    return {
        title = "Multicast Timecode Broadcaster",
        version = "1.0",
        author = "You",
        url = "https://github.com/emanspeaks/zig-vorne-m1000",
        shortdesc = "Broadcasts filename + playhead over multicast",
        description = "Pushes current VLC playback status as UDP multicast JSON",
        capabilities = {}
    }
end

local udp
local mcast_addr = "239.255.0.1"
local mcast_port = 5005
local running = false

-- Activate when user enables extension
function activate()
    msg.info("[multicast_time] Activated")
    udp = vlc.net.udp_socket()
    vlc.net.connect_udp(udp, mcast_addr, mcast_port)
    running = true
    vlc.timer.register(250, push_status)  -- every 250ms
end

-- Deactivate on exit
function deactivate()
    msg.info("[multicast_time] Deactivated")
    if udp then vlc.net.close(udp) end
    running = false
end

function push_status()
    if not running then return end
    local item = vlc.input.item()
    if not item then return end
    local meta = item:metas()
    local name = meta["filename"] or meta["title"] or "unknown"
    local input = vlc.object.input()
    if not input then return end
    local time = vlc.var.get(input, "time")
    local length = vlc.var.get(input, "length")
    local state = vlc.var.get(input, "state")
    local payload = string.format(
        '{"filename":"%s","time":%d,"length":%d,"state":"%s"}',
        name, time, length, state or "unknown"
    )
    vlc.net.send(udp, payload)
end
