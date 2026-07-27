const std = @import("std");
const dbg = @import("debug_log.zig");
const Io = std.Io;
const protocol = @import("protocol.zig");
const config = @import("config.zig");
const time = @import("time.zig");
const process_mgmt = @import("process_mgmt.zig");
const str_utils = @import("str_utils.zig");
const frame_timer = @import("frame_timer.zig");
const mode_mod = @import("mode.zig");
const Mode = mode_mod.Mode;

const Writer = std.Io.Writer;
const maxbufsz = str_utils.maxbufsz;

pub const PLAYCHAR = protocol.DLE ++ "P"; // ►
pub const PAUSECHAR = "\xba"; // ║
pub const STOPCHAR = protocol.DLE ++ "G"; // ■

// 0.16 removed the process-global environment accessors; the environment block
// is handed to `main` instead. `setEnviron` records it so the debug check below
// keeps working without an allocator.
var vlc_environ: std.process.Environ = .empty;

pub fn setEnviron(environ: std.process.Environ) void {
    vlc_environ = environ;
}

// Check if VLC debug mode is enabled via environment variable
fn isVlcDebugEnabled() bool {
    const value = vlc_environ.getPosix("DEBUG_VLC") orelse return false;
    return std.mem.eql(u8, value, "1");
}

/// Print if VLC diagnostics are switched on, by either mechanism.
///
/// `debug.vlc` in the config file is the general one and matches every other
/// category in this program; `DEBUG_VLC=1` predates it and is kept working
/// rather than quietly removed, since it costs one call to honour it and
/// anything already relying on it would otherwise go silent with no error to
/// explain why.
fn debugPrint(comptime fmt: []const u8, args: anytype) void {
    if (dbg.enabled(.vlc) or isVlcDebugEnabled()) {
        std.debug.print(fmt, args);
    }
}

pub fn runVlcClocks(io: Io, allocator: std.mem.Allocator, port: anytype, mode: *std.atomic.Value(Mode)) !void {
    dbg.print(.vlc, "Starting VLC run mode...\n", .{});

    // Build the command string dynamically
    var cmd_parts = std.ArrayList(u8).empty;
    defer cmd_parts.deinit(allocator);

    var playtime_buf: [maxbufsz]u8 = undefined;
    var linebuf: [maxbufsz]u8 = undefined;
    var playtime_ms: u64 = 0;
    var filename: []const u8 = "(No media)";

    // Initialize frame timer for real-time operation
    var timer = frame_timer.FrameTimer.init(io, 4.0); // 5 FPS target to match server

    // Initialize VLC player
    var player = VlcPlayer.init(io, allocator);
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

        // A re-init was requested from the web page. Stop, and let
        // the dispatch loop in `main` service it: it owns the serial
        // port on this thread, and re-entering this function repaints
        // from scratch because the "what is on the panel" records
        // start empty. Checked without consuming -- `main` clears it.
        if (mode_mod.reinitPending()) {
            std.debug.print("Re-init requested, exiting vlc mode...\n", .{});
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

        // Interpolate play time if playing
        if (player.state.run_status == .Playing and player.last_message_time > 0) {
            const now = time.nowMillis(io);
            const last_msg_i64: i64 = @intCast(player.last_message_time);
            const elapsed = now - last_msg_i64;
            const elapsed_u: u64 = if (elapsed > 0) @intCast(elapsed) else 0;
            player.state.play_time_ms = player.last_vlc_time + elapsed_u;
        }

        playtime_ms = player.state.play_time_ms;
        filename = player.state.filename;

        const playtime_sec = @divFloor(playtime_ms, 1000);
        const playtime_sec_i64: i64 = @intCast(playtime_sec);
        const playtime_hms = time.timedeltaToHms(playtime_sec_i64);
        const playtime_str = time.formatHms(playtime_hms, &playtime_buf) catch unreachable;
        const runstatus_str = switch (player.state.run_status) {
            .Stopped => STOPCHAR,
            .Playing => PLAYCHAR,
            .Paused => PAUSECHAR,
        };

        // Display filename on first line
        try str_utils.clearVorneLineBuf(&linebuf);
        try str_utils.copyLeftJustify(&linebuf, filename, 20, null);
        cmd_parts.clearAndFree(allocator);
        try protocol.appendStrToCmdList(allocator, &cmd_parts, 1, 1, &linebuf);
        const cmd1_slice = try cmd_parts.toOwnedSlice(allocator);
        defer allocator.free(cmd1_slice);
        protocol.sendUnitDisplayCmd(allocator, port, 1, cmd1_slice) catch |err| return err;

        // Display time on second line
        try str_utils.clearVorneLineBuf(&linebuf);
        try str_utils.copyLeftJustify(&linebuf, playtime_str, 20 - runstatus_str.len, null);
        try str_utils.copyRightJustify(&linebuf, runstatus_str, 1, 0);
        cmd_parts.clearAndFree(allocator);
        try protocol.appendStrToCmdList(allocator, &cmd_parts, 2, 1, &linebuf);
        const cmd2_slice = try cmd_parts.toOwnedSlice(allocator);
        defer allocator.free(cmd2_slice);
        protocol.sendUnitDisplayCmd(allocator, port, 1, cmd2_slice) catch |err| return err;

        // Handle frame timing and sleep
        try timer.frameEnd();
    }
}

pub const VlcPlayerRunStatus = enum {
    Stopped,
    Playing,
    Paused,
};

pub const VlcPlayerState = struct {
    play_time_ms: u64,
    run_status: VlcPlayerRunStatus,
    filename: []const u8,
    length_ms: u64,

    pub fn init(allocator: std.mem.Allocator) VlcPlayerState {
        return VlcPlayerState{
            .play_time_ms = 0,
            .run_status = .Stopped,
            .filename = std.fmt.allocPrint(allocator, "No media", .{}) catch unreachable,
            .length_ms = 0,
        };
    }

    pub fn deinit(self: *VlcPlayerState, allocator: std.mem.Allocator) void {
        allocator.free(self.filename);
    }
};

pub const VlcPlayer = struct {
    io: Io,
    allocator: std.mem.Allocator,
    state: VlcPlayerState,
    socket: ?Io.net.Socket,
    last_update_time: i64,
    last_processed_ts: u64,
    last_vlc_time: u64,
    last_message_time: u64,

    const Self = @This();
    const MULTICAST_ADDR = "239.255.0.100";
    const MULTICAST_PORT = 8888;
    /// How long to wait for a datagram before concluding none are pending.
    const RECV_TIMEOUT: Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } };

    /// Initialize a new VlcPlayer instance
    pub fn init(io: Io, allocator: std.mem.Allocator) Self {
        return Self{
            .io = io,
            .allocator = allocator,
            .state = VlcPlayerState.init(allocator),
            .socket = null,
            .last_update_time = 0,
            .last_processed_ts = 0,
            .last_vlc_time = 0,
            .last_message_time = 0,
        };
    }

    /// Cleanup resources
    pub fn deinit(self: *Self) void {
        self.state.deinit(self.allocator);
        if (self.socket) |sock| {
            sock.close(self.io);
        }
    }

    /// Update player state from multicast messages
    pub fn updateState(self: *Self) !void {
        if (self.socket == null) {
            try self.connectMulticast();
        }

        // Receive all available messages, keeping only the latest
        var latest_message: ?[]const u8 = null;
        var latest_server_ts_ms: ?i64 = null;
        var latest_bytes: usize = 0;

        while (true) {
            var buffer: [1024]u8 = undefined;

            const result = self.socket.?.receiveTimeout(self.io, &buffer, Self.RECV_TIMEOUT);

            if (result) |incoming| {
                const bytes_read = incoming.data.len;
                const message = self.allocator.dupe(u8, incoming.data) catch {
                    std.debug.print("VLC: Failed to allocate memory for message\n", .{});
                    continue;
                };

                // Parse server_timestamp to compare
                var json = std.json.parseFromSlice(std.json.Value, self.allocator, message, .{}) catch {
                    std.debug.print("VLC: JSON parse error\n", .{});
                    self.allocator.free(message);
                    continue;
                };
                defer json.deinit();

                var server_ts_ms: ?i64 = null;
                if (json.value == .object) {
                    const obj = &json.value.object;
                    if (obj.get("server_timestamp")) |ts_val| {
                        if (ts_val == .integer) {
                            server_ts_ms = ts_val.integer;
                        }
                    }
                }

                // Keep the latest message
                if (latest_message) |old_msg| {
                    self.allocator.free(old_msg);
                }
                latest_message = message;
                latest_server_ts_ms = server_ts_ms;
                latest_bytes = bytes_read;
            } else |err| switch (err) {
                error.Timeout => {
                    // No more messages
                    break;
                },
                else => {
                    std.debug.print("VLC: Socket error: {}\n", .{err});
                    if (latest_message) |msg| self.allocator.free(msg);
                    return err;
                },
            }
        }

        // Process the latest message if any
        if (latest_message) |message| {
            defer self.allocator.free(message);

            const now_ms = time.nowMillis(self.io);

            // Parse and process the latest message
            var json = std.json.parseFromSlice(std.json.Value, self.allocator, message, .{}) catch {
                std.debug.print("VLC: JSON parse error\n", .{});
                return;
            };
            defer json.deinit();

            var server_ts_ms: ?i64 = null;
            if (json.value == .object) {
                const obj = &json.value.object;
                if (obj.get("server_timestamp")) |ts_val| {
                    if (ts_val == .integer) {
                        server_ts_ms = ts_val.integer;
                    }
                }
            }

            var delta_ms: ?i64 = null;
            if (server_ts_ms) |ts_ms| {
                delta_ms = now_ms - ts_ms;
                // Discard if message is older than last processed
                if (ts_ms <= self.last_processed_ts) {
                    debugPrint("VLC: Discarding old message (server_ts: {}, last_processed: {})\n", .{ ts_ms, self.last_processed_ts });
                    return;
                }
                self.last_processed_ts = std.math.cast(u64, ts_ms) orelse 0;
            }
            debugPrint("VLC: Received {} bytes. Server ts: {any}, Local ts: {}, Delta: {any} ms\n", .{ latest_bytes, latest_server_ts_ms, now_ms, delta_ms });
            try self.parseMessage(message);
            if (server_ts_ms) |ts_ms| {
                self.last_message_time = std.math.cast(u64, ts_ms) orelse 0;
            }
        }
    }

    /// Connect to multicast group
    fn connectMulticast(self: *Self) !void {
        dbg.print(.vlc, "Creating UDP socket for VLC status multicast...\n", .{});

        // `IpAddress.bind` would create and bind the socket in one step, but it
        // offers no way to set SO_REUSEADDR/SO_REUSEPORT, which must be applied
        // *before* bind so several receivers can share the multicast port. So
        // create the socket by hand and wrap the fd in an `Io.net.Socket`.
        const linux = std.os.linux;
        const sock_fd: std.posix.socket_t = blk: {
            const rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
            if (linux.errno(rc) != .SUCCESS) return error.SocketCreateFailed;
            break :blk @intCast(rc);
        };
        errdefer _ = linux.close(sock_fd);

        dbg.print(.vlc, "VLC: Socket created successfully\n", .{});

        // Allow multiple sockets to bind to the same port
        try std.posix.setsockopt(sock_fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        try std.posix.setsockopt(sock_fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));

        // Bind to the multicast port
        const bind_address: Io.net.IpAddress = try .parse("0.0.0.0", Self.MULTICAST_PORT);
        var sa: linux.sockaddr.in = .{
            .port = std.mem.nativeToBig(u16, Self.MULTICAST_PORT),
            .addr = 0, // INADDR_ANY
        };
        if (linux.errno(linux.bind(sock_fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in))) != .SUCCESS) {
            return error.BindFailed;
        }

        // The receive timeout that used to be set via SO_RCVTIMEO is now passed
        // per-call to `receiveTimeout`.
        const sock: Io.net.Socket = .{ .handle = sock_fd, .address = bind_address };
        self.socket = sock;

        dbg.print(.vlc, "VLC: Bound to 0.0.0.0:{}\n", .{Self.MULTICAST_PORT});

        // Join the multicast group using raw socket options
        const multicast_addr: Io.net.IpAddress = try .parse(Self.MULTICAST_ADDR, Self.MULTICAST_PORT);

        // Create the ip_mreq structure manually
        var mreq: [8]u8 = undefined; // ip_mreq is 8 bytes
        // imr_multiaddr (first 4 bytes) - multicast group address, network byte order
        @memcpy(mreq[0..4], &multicast_addr.ip4.bytes);
        // imr_interface (next 4 bytes) - interface address (INADDR_ANY)
        @memset(mreq[4..8], 0);

        try std.posix.setsockopt(sock.handle, std.posix.IPPROTO.IP, std.os.linux.IP.ADD_MEMBERSHIP, &mreq);

        dbg.print(.vlc, "VLC: Joined multicast group {s}\n", .{Self.MULTICAST_ADDR});
    }

    /// Parse JSON message from VLC extension
    fn parseMessage(self: *Self, message: []const u8) !void {
        debugPrint("VLC: Parsing message: {s}\n", .{message});

        // Parse the new JSON format from C server: {"server_timestamp":<ms>,"server_id":"...","vlc_data":{...}}
        var json = std.json.parseFromSlice(std.json.Value, self.allocator, message, .{}) catch {
            std.debug.print("VLC: JSON parse error\n", .{});
            return;
        };
        defer json.deinit();

        if (json.value != .object) {
            std.debug.print("VLC: Root is not an object\n", .{});
            return;
        }

        const obj = &json.value.object;

        // Get the vlc_data object
        const vlc_data = obj.get("vlc_data") orelse {
            std.debug.print("VLC: No vlc_data found in message\n", .{});
            return;
        };

        if (vlc_data != .object) {
            std.debug.print("VLC: vlc_data is not an object\n", .{});
            return;
        }

        const data_obj = &vlc_data.object;

        // Parse title or filename
        var new_display_name: ?[]const u8 = null;
        if (data_obj.get("title")) |title_val| {
            if (title_val == .string and title_val.string.len > 0) {
                new_display_name = title_val.string;
                debugPrint("VLC: Parsed title: {s}\n", .{title_val.string});
            }
        }
        if (new_display_name == null) {
            if (data_obj.get("filename")) |filename_val| {
                if (filename_val == .string) {
                    new_display_name = filename_val.string;
                    debugPrint("VLC: Parsed filename: {s}\n", .{filename_val.string});
                }
            }
        }
        if (new_display_name) |name| {
            // Free old filename and allocate new one
            self.allocator.free(self.state.filename);
            self.state.filename = try self.allocator.dupe(u8, name);
        }

        // Parse duration (in milliseconds)
        if (data_obj.get("duration")) |duration_val| {
            if (duration_val == .integer) {
                self.state.length_ms = std.math.cast(u64, duration_val.integer) orelse 0;
                debugPrint("VLC: Parsed duration: {} ms\n", .{duration_val.integer});
            }
        }

        // Parse time (in milliseconds) - now the primary source of timing
        if (data_obj.get("time")) |time_val| {
            if (time_val == .integer) {
                const time_ms = std.math.cast(u64, time_val.integer) orelse 0;
                self.state.play_time_ms = time_ms;
                self.last_vlc_time = time_ms;
                debugPrint("VLC: Parsed time: {} ms\n", .{time_val.integer});
            }
        }

        // Parse playing state
        if (data_obj.get("is_playing")) |playing_val| {
            if (playing_val == .bool) {
                debugPrint("VLC: Parsed is_playing: {}\n", .{playing_val.bool});
                if (playing_val.bool) {
                    self.state.run_status = .Playing;
                } else {
                    // Could be paused or stopped, we'll assume paused for now
                    self.state.run_status = .Paused;
                }
            }
        }

        debugPrint("VLC: State updated successfully\n", .{});
    }

    /// Get the current player state (for debugging/monitoring)
    pub fn getState(self: *Self) VlcPlayerState {
        return self.state;
    }
};
