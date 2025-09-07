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
    var timer = frame_timer.FrameTimer.init(2.0); // 2 FPS target

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
    last_processed_ts: i64,

    const Self = @This();
    const MULTICAST_ADDR = "239.255.0.100";
    const MULTICAST_PORT = 8888;

    /// Initialize a new VlcPlayer instance
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .state = VlcPlayerState.init(allocator),
            .socket = null,
            .last_update_time = 0,
            .last_processed_ts = 0,
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

        // Receive all available messages, keeping only the latest
        var latest_message: ?[]const u8 = null;
        var latest_server_ts: ?[]const u8 = null;
        var latest_bytes: usize = 0;

        while (true) {
            var buffer: [1024]u8 = undefined;
            var addr: std.net.Address = undefined;
            var addr_len: std.posix.socklen_t = @sizeOf(std.net.Address);

            const result = std.posix.recvfrom(self.socket.?, &buffer, 0, &addr.any, &addr_len);

            if (result) |bytes_read| {
                const message = self.allocator.dupe(u8, buffer[0..bytes_read]) catch {
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

                var server_ts: ?[]const u8 = null;
                if (json.value == .object) {
                    const obj = &json.value.object;
                    if (obj.get("server_timestamp")) |ts_val| {
                        if (ts_val == .string) {
                            server_ts = ts_val.string;
                        }
                    }
                }

                // Keep the latest message
                if (latest_message) |old_msg| {
                    self.allocator.free(old_msg);
                }
                latest_message = message;
                latest_server_ts = server_ts;
                latest_bytes = bytes_read;
            } else |err| switch (err) {
                error.WouldBlock => {
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

            // Parse and process the latest message
            var json = std.json.parseFromSlice(std.json.Value, self.allocator, message, .{}) catch {
                std.debug.print("VLC: JSON parse error\n", .{});
                return;
            };
            defer json.deinit();

            var server_ts: ?[]const u8 = null;
            if (json.value == .object) {
                const obj = &json.value.object;
                if (obj.get("server_timestamp")) |ts_val| {
                    if (ts_val == .string) {
                        server_ts = ts_val.string;
                    }
                }
            }

            var delta_sec: ?i64 = null;
            if (server_ts) |ts| {
                // Parse timestamp string: "YYYY-MM-DD HH:MM:SS"
                const year = try std.fmt.parseInt(u16, ts[0..4], 10);
                const month = try std.fmt.parseInt(u8, ts[5..7], 10);
                const day = try std.fmt.parseInt(u8, ts[8..10], 10);
                const hour = try std.fmt.parseInt(u8, ts[11..13], 10);
                const min = try std.fmt.parseInt(u8, ts[14..16], 10);
                const sec = try std.fmt.parseInt(u8, ts[17..19], 10);
                const server_epoch_local = time.ymdhmsToTimestamp(time.Ymdhms{
                    .year = year,
                    .month = month,
                    .day = day,
                    .hour = hour,
                    .minute = min,
                    .second = sec,
                });
                // Server time is in local timezone, get dynamic offset to UTC
                const zi = time.getTimezoneInfo();
                const tz_offset_sec = zi.offset_sec;
                const server_epoch_utc = server_epoch_local - tz_offset_sec;
                const now_epoch = std.time.timestamp();

                // Discard if message is older than last processed
                if (server_epoch_utc <= self.last_processed_ts) {
                    std.debug.print("VLC: Discarding old message (server_ts: {}, last_processed: {})\n", .{ server_epoch_utc, self.last_processed_ts });
                    return;
                }

                delta_sec = now_epoch - server_epoch_utc;
                self.last_processed_ts = server_epoch_utc;
            }
            std.debug.print("VLC: Received {} bytes. Server ts: {s}, Local ts: {}, Delta: {any} sec\n", .{ latest_bytes, server_ts orelse "(none)", std.time.timestamp(), delta_sec });
            try self.parseMessage(message);
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

        // Parse the new JSON format from C server: {"server_timestamp":"...","server_id":"...","vlc_data":{...}}
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

        // Parse filename
        if (data_obj.get("filename")) |filename_val| {
            if (filename_val == .string) {
                const new_filename = filename_val.string;
                std.debug.print("VLC: Parsed filename: {s}\n", .{new_filename});
                // Free old filename and allocate new one
                self.allocator.free(self.state.filename);
                self.state.filename = try self.allocator.dupe(u8, new_filename);
            }
        }

        // Parse time (in milliseconds, convert to seconds)
        if (data_obj.get("time")) |time_val| {
            if (time_val == .integer) {
                self.state.play_time_seconds = @intCast(@divTrunc(time_val.integer, 1000));
                std.debug.print("VLC: Parsed time: {} ms ({} s)\n", .{ time_val.integer, self.state.play_time_seconds });
            }
        }

        // Parse duration (in milliseconds, convert to seconds)
        if (data_obj.get("duration")) |duration_val| {
            if (duration_val == .integer) {
                self.state.length_seconds = @intCast(@divTrunc(duration_val.integer, 1000));
                std.debug.print("VLC: Parsed duration: {} ms ({} s)\n", .{ duration_val.integer, self.state.length_seconds });
            }
        }

        // Parse playing state
        if (data_obj.get("is_playing")) |playing_val| {
            if (playing_val == .bool) {
                std.debug.print("VLC: Parsed is_playing: {}\n", .{playing_val.bool});
                if (playing_val.bool) {
                    self.state.run_status = .Playing;
                } else {
                    // Could be paused or stopped, we'll assume paused for now
                    self.state.run_status = .Paused;
                }
            }
        }

        std.debug.print("VLC: State updated successfully\n", .{});
    }

    /// Get the current player state (for debugging/monitoring)
    pub fn getState(self: *Self) VlcPlayerState {
        return self.state;
    }
};
