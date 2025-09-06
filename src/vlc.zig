const std = @import("std");
const protocol = @import("protocol.zig");
const config = @import("config.zig");
const time = @import("time.zig");
const process_mgmt = @import("process_mgmt.zig");
const str_utils = @import("str_utils.zig");
const frame_timer = @import("frame_timer.zig");
const Mode = @import("mode.zig").Mode;

const Writer = std.Io.Writer;
const maxbufsz = str_utils.maxbufsz;

pub const PLAYCHAR = protocol.DLE ++ "P"; // ►
pub const PAUSECHAR = "\xba"; // ║
pub const STOPCHAR = protocol.DLE ++ "G"; // ■

pub fn runVlcClocks(allocator: std.mem.Allocator, port: anytype, mode: *std.atomic.Value(Mode)) !void {
    std.debug.print("Starting VLC run mode...\n", .{});

    // Build the command string dynamically
    var cmd_parts = std.ArrayList(u8){};
    defer cmd_parts.deinit(allocator);

    var playtime_buf: [maxbufsz]u8 = undefined;
    var linebuf: [maxbufsz]u8 = undefined;
    var playtime: u32 = 0;
    var filename: []const u8 = "No media";

    // Initialize frame timer for real-time operation
    var timer = frame_timer.FrameTimer.init(1.0); // 1 FPS target

    // Initialize VLC player
    var player = VlcPlayer.init(allocator);
    defer player.deinit();

    while (true) {
        // Start frame timing
        timer.frameStart();

        // Check for shutdown signal
        if (process_mgmt.shouldShutdown()) {
            std.debug.print("VLC display received shutdown signal, exiting gracefully...\n", .{});
            return;
        }

        // Check for mode change
        if (mode.load(.acquire) != .Vlc) {
            std.debug.print("Mode changed, exiting vlc mode...\n", .{});
            return;
        }

        playtime_buf = undefined;
        cmd_parts.clearAndFree(allocator);
        try str_utils.clearVorneLineBuf(&linebuf);

        // Get current local timestamp
        // const utc_timestamp = std.time.timestamp();

        // Update VLC state
        player.updateState() catch |err| {
            std.debug.print("Failed to update VLC state: {}\n", .{err});
        };

        playtime = player.state.play_time_seconds;
        filename = player.state.filename;

        const playtime_hms = time.timedeltaToHms(playtime);
        const playtime_str = time.formatHms(playtime_hms, &playtime_buf) catch unreachable;
        const runstatus_str = switch (player.state.run_status) {
            .Stopped => STOPCHAR,
            .Playing => PLAYCHAR,
            .Paused => PAUSECHAR,
        };

        // Display filename on first line, time on second
        try str_utils.copyLeftJustify(&linebuf, filename, 20, null);
        try protocol.appendStrToCmdList(allocator, &cmd_parts, 1, 1, &linebuf);

        try str_utils.clearVorneLineBuf(&linebuf);
        try str_utils.copyLeftJustify(&linebuf, playtime_str, 20 - runstatus_str.len, null);
        try str_utils.copyRightJustify(&linebuf, runstatus_str, 1, 0);
        try protocol.appendStrToCmdList(allocator, &cmd_parts, 2, 1, &linebuf);

        const cmd_slice = try cmd_parts.toOwnedSlice(allocator);
        if (cmd_slice.len > 0) {
            protocol.sendUnitDisplayCmd(allocator, port, 1, cmd_slice) catch |err| return err;
        }

        // Handle frame timing and sleep
        timer.frameEnd();
    }
}

pub const VlcPlayerRunStatus = enum {
    Stopped,
    Playing,
    Paused,
};

pub const VlcPlayerState = struct {
    play_time_seconds: u32,
    run_status: VlcPlayerRunStatus,
    filename: []const u8,
    length_seconds: u32,

    pub fn init(allocator: std.mem.Allocator) VlcPlayerState {
        return VlcPlayerState{
            .play_time_seconds = 0,
            .run_status = .Stopped,
            .filename = std.fmt.allocPrint(allocator, "No media", .{}) catch unreachable,
            .length_seconds = 0,
        };
    }

    pub fn deinit(self: *VlcPlayerState, allocator: std.mem.Allocator) void {
        allocator.free(self.filename);
    }
};

pub const VlcPlayer = struct {
    allocator: std.mem.Allocator,
    state: VlcPlayerState,
    socket: ?std.posix.socket_t,
    last_update_time: i64,

    const Self = @This();
    const MULTICAST_ADDR = "239.255.0.1";
    const MULTICAST_PORT = 5005;

    /// Initialize a new VlcPlayer instance
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .state = VlcPlayerState.init(allocator),
            .socket = null,
            .last_update_time = 0,
        };
    }

    /// Cleanup resources
    pub fn deinit(self: *Self) void {
        self.state.deinit(self.allocator);
        if (self.socket) |sock| {
            std.posix.close(sock);
        }
    }

    /// Update player state from multicast messages
    pub fn updateState(self: *Self) !void {
        if (self.socket == null) {
            try self.connectMulticast();
        }

        // Try to receive a message with timeout
        var buffer: [1024]u8 = undefined;
        var addr: std.net.Address = undefined;
        var addr_len: std.posix.socklen_t = @sizeOf(std.net.Address);

        const result = std.posix.recvfrom(self.socket.?, &buffer, 0, &addr.any, &addr_len);

        if (result) |bytes_read| {
            const message = buffer[0..bytes_read];
            std.debug.print("VLC: Received {} bytes: {s}\n", .{bytes_read, message});
            try self.parseMessage(message);
        } else |err| switch (err) {
            error.WouldBlock => {
                // No message received, keep current state
                return;
            },
            else => {
                std.debug.print("VLC: Socket error: {}\n", .{err});
                return err;
            },
        }
    }

    /// Connect to multicast group
    fn connectMulticast(self: *Self) !void {
        std.debug.print("VLC: Creating UDP socket...\n", .{});

        // Create UDP socket
        self.socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC, 0);
        errdefer if (self.socket) |sock| std.posix.close(sock);

        std.debug.print("VLC: Socket created successfully\n", .{});

        // Set receive timeout
        const timeout = std.posix.timeval{
            .sec = 0,
            .usec = 100_000, // 100ms
        };
        try std.posix.setsockopt(self.socket.?, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));

        // Allow multiple sockets to bind to the same port
        try std.posix.setsockopt(self.socket.?, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        try std.posix.setsockopt(self.socket.?, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));

        // Bind to the multicast port
        const bind_address = try std.net.Address.parseIp("0.0.0.0", Self.MULTICAST_PORT);
        try std.posix.bind(self.socket.?, &bind_address.any, bind_address.getOsSockLen());

        std.debug.print("VLC: Bound to 0.0.0.0:{}\n", .{Self.MULTICAST_PORT});

        // Join the multicast group using raw socket options
        const multicast_addr = try std.net.Address.parseIp(Self.MULTICAST_ADDR, Self.MULTICAST_PORT);

        // Create the ip_mreq structure manually
        var mreq: [8]u8 = undefined; // ip_mreq is 8 bytes
        // imr_multiaddr (first 4 bytes) - multicast group address
        const group_addr = std.mem.nativeToLittle(u32, multicast_addr.in.sa.addr);
        @memcpy(mreq[0..4], std.mem.asBytes(&group_addr));
        // imr_interface (next 4 bytes) - interface address (INADDR_ANY)
        const iface_addr = std.mem.nativeToLittle(u32, 0); // INADDR_ANY
        @memcpy(mreq[4..8], std.mem.asBytes(&iface_addr));

        try std.posix.setsockopt(self.socket.?, std.posix.IPPROTO.IP, std.os.linux.IP.ADD_MEMBERSHIP, &mreq);

        std.debug.print("VLC: Joined multicast group {s}\n", .{Self.MULTICAST_ADDR});
    }

    /// Parse JSON message from VLC extension
    fn parseMessage(self: *Self, message: []const u8) !void {
        std.debug.print("VLC: Parsing message: {s}\n", .{message});

        // Simple JSON parsing for the expected format: {"filename":"name","time":123,"length":456,"state":"playing"}
        var json = try std.json.parseFromSlice(std.json.Value, self.allocator, message, .{});
        defer json.deinit();

        const obj = &json.value.object;

        // Parse filename
        if (obj.get("filename")) |filename_val| {
            const new_filename = filename_val.string;
            std.debug.print("VLC: Parsed filename\n", .{});
            // Free old filename and allocate new one
            self.allocator.free(self.state.filename);
            self.state.filename = try self.allocator.dupe(u8, new_filename);
        }

        // Parse time
        if (obj.get("time")) |time_val| {
            self.state.play_time_seconds = @intCast(time_val.integer);
            std.debug.print("VLC: Parsed time\n", .{});
        }

        // Parse length
        if (obj.get("length")) |length_val| {
            self.state.length_seconds = @intCast(length_val.integer);
            std.debug.print("VLC: Parsed length\n", .{});
        }

        // Parse state
        if (obj.get("state")) |state_val| {
            const state_str = state_val.string;
            std.debug.print("VLC: Parsed state\n", .{});
            if (std.mem.eql(u8, state_str, "playing")) {
                self.state.run_status = .Playing;
            } else if (std.mem.eql(u8, state_str, "paused")) {
                self.state.run_status = .Paused;
            } else {
                self.state.run_status = .Stopped;
            }
        }

        std.debug.print("VLC: State updated\n", .{});
    }

    /// Get the current player state (for debugging/monitoring)
    pub fn getState(self: *Self) VlcPlayerState {
        return self.state;
    }
};
