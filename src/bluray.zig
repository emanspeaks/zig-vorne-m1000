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

pub fn runBlurayClocks(allocator: std.mem.Allocator, port: anytype, mode: *std.atomic.Value(Mode)) !void {
    std.debug.print("Starting Blu-Ray run mode...\n", .{});

    // Build the command string dynamically
    var cmd_parts = std.ArrayList(u8){};
    defer cmd_parts.deinit(allocator);

    var playtime_buf: [maxbufsz]u8 = undefined;
    var linebuf: [maxbufsz]u8 = undefined;
    var playtime: u32 = 0;

    // Initialize frame timer for real-time operation
    var timer = frame_timer.FrameTimer.init(1.0); // 1 FPS target

    // Initialize Blu-ray player
    var player = BlurayPlayer.init(allocator);
    defer player.deinit();

    // Load configuration from JSON
    const bluray_config = config.loadBlurayConfig(allocator);

    while (true) {
        // Start frame timing
        timer.frameStart();

        // Check for shutdown signal
        if (process_mgmt.shouldShutdown()) {
            std.debug.print("Blu-Ray display received shutdown signal, exiting gracefully...\n", .{});
            return;
        }

        // Check for mode change
        if (mode.load(.acquire) != .Bluray) {
            std.debug.print("Mode changed, exiting bluray mode...\n", .{});
            return;
        }

        playtime_buf = undefined;
        cmd_parts.clearAndFree(allocator);
        try str_utils.clearVorneLineBuf(&linebuf);

        // Get current local timestamp
        // const utc_timestamp = std.time.timestamp();

        // calculate total running time
        playtime = player.getCurrentPlayTime();
        const playtime_hms = time.timedeltaToHms(playtime);
        const playtime_str = time.formatHms(playtime_hms, &playtime_buf) catch unreachable;
        const runstatus_str = switch (player.state.run_status) {
            .Stopped => STOPCHAR,
            .Playing => PLAYCHAR,
            .Paused => PAUSECHAR,
        };

        if (bluray_config != null) {
            try str_utils.copyLeftJustify(&linebuf, &bluray_config.?.label, 20 - playtime_str.len, null);
        }
        try str_utils.copyRightJustify(&linebuf, playtime_str, @min(playtime_str.len, 20), 1);
        try str_utils.copyRightJustify(&linebuf, runstatus_str, 1, 0);
        try protocol.appendStrToCmdList(allocator, &cmd_parts, 1, 1, &linebuf);

        if (bluray_config) |cfg| {
            _ = cfg;
        }

        try protocol.appendStrToCmdList(allocator, &cmd_parts, 2, 1, "Blu-Ray mode");

        const cmd_slice = try cmd_parts.toOwnedSlice(allocator);
        if (cmd_slice.len > 0) {
            protocol.sendUnitDisplayCmd(allocator, port, 1, cmd_slice) catch |err| return err;
        }

        // Handle frame timing and sleep
        timer.frameEnd();
    }
}

pub const BlurayPlayerRunStatus = enum {
    Stopped,
    Playing,
    Paused,
};

pub const BlurayPlayerState = struct {
    play_time_seconds: u32,
    run_status: BlurayPlayerRunStatus,
    is_standby: bool,
    is_off: bool,
    // Add more fields as needed for player state

    pub fn init() BlurayPlayerState {
        return BlurayPlayerState{
            .play_time_seconds = 0,
            .run_status = .Stopped,
            .is_standby = true,
            .is_off = false,
        };
    }
};

/// Commands that can be sent to the Blu-ray player
pub const Command = enum {
    Play,
    Stop,
    Pause,
    Next,
    Previous,
    Power,
    OpenClose,
};

pub const BlurayPlayer = struct {
    allocator: std.mem.Allocator,
    ip_address: ?[]const u8,
    state: BlurayPlayerState,
    last_update_time: i64,
    http_client: std.http.Client,

    const Self = @This();
    const USER_AGENT = "MEI-LAN-REMOTE-CALL";

    /// Initialize a new BlurayPlayer instance
    pub fn init(allocator: std.mem.Allocator) Self {
        var ip_address = config.loadBlurayIp(allocator);
        if (ip_address) |ip| {
            ip_address = std.mem.trimRight(u8, ip, "\r\n");
        }

        return Self{
            .allocator = allocator,
            .ip_address = ip_address,
            .state = BlurayPlayerState.init(),
            .last_update_time = 0,
            .http_client = std.http.Client{ .allocator = allocator },
        };
    }

    /// Cleanup resources
    pub fn deinit(self: *Self) void {
        self.http_client.deinit();
        if (self.ip_address) |ip| {
            self.allocator.free(ip);
        }
    }

    /// Get the current play time in seconds
    pub fn getCurrentPlayTime(self: *Self) u32 {
        // Update state if needed (could implement caching/rate limiting here)
        self.getStatus() catch |err| {
            std.debug.print("Failed to get Blu-ray status: {}\n", .{err});
            return self.state.play_time_seconds; // Return last known value
        };

        return self.state.play_time_seconds;
    }

    /// Internal method to update player state from the actual device
    fn getStatus(self: *Self) !void {
        if (self.ip_address == null) {
            return error.NoIpAddress;
        }

        const url = try std.fmt.allocPrint(self.allocator, "http://{s}/WAN/dvdr/dvdr_ctrl.cgi", .{self.ip_address.?});
        defer self.allocator.free(url);

        const body_data = "cCMD_PST.x=100&cCMD_PST.y=100";
        const response = self.sendHttpRequest(url, body_data) catch |err| switch (err) {
            error.HttpRequestFailed => {
                self.state.is_off = true;
                return;
            },
            else => return err,
        };
        defer self.allocator.free(response);

        const parsed = self.parseResponse(response) catch |err| {
            return err;
        };
        defer self.allocator.free(parsed);

        if (parsed.len >= 4) {
            // State response format: ['0', '0', '0', '00000000']
            // 0: State (0 == stopped / 1 == playing / 2 == paused)
            // 1: Playing time (-2 for no disc?)

            const play_state_raw = std.fmt.parseInt(u32, parsed[0], 10) catch 0;
            const play_state: BlurayPlayerRunStatus = switch (play_state_raw) {
                0 => .Stopped,
                1 => .Playing,
                2 => .Paused,
                else => .Stopped, // Default to stopped for unknown values
            };
            const play_time = std.fmt.parseInt(u32, parsed[1], 10) catch 0;

            // Update play time if valid
            if (play_time != std.math.maxInt(u32) - 1) { // -2 becomes maxInt-1 when parsed as u32
                self.state.play_time_seconds = play_time;
            } else {
                self.state.play_time_seconds = 0;
                self.state.is_standby = true; // No disc or deep standby
            }

            self.state.run_status = play_state;
            self.state.is_standby = play_state == .Stopped;
            self.state.is_off = false;
        }
    }

    /// Send HTTP request to the Blu-ray player
    fn sendHttpRequest(self: *Self, url: []const u8, body: []const u8) ![]u8 {
        // Use Writer.Allocating for collecting HTTP response data
        var allocating_writer = std.io.Writer.Allocating.init(self.allocator);
        defer allocating_writer.deinit();

        const response = try self.http_client.fetch(.{
            .method = .POST,
            .location = .{ .url = url },
            .payload = body,
            .headers = .{
                .user_agent = .{ .override = BlurayPlayer.USER_AGENT },
                .accept_encoding = .{ .override = "application/json" },
            },
            .response_writer = &allocating_writer.writer,
        });

        // Check if request was successful
        if (response.status != .ok) {
            return error.HttpRequestFailed;
        }

        // Return the collected response data
        return allocating_writer.toOwnedSlice();
    }

    /// Parse the response from the Blu-ray player
    fn parseResponse(self: *Self, response: []const u8) ![][]const u8 {
        // Split response by \r\n
        var lines = std.ArrayList([]const u8){};
        defer lines.deinit(self.allocator);

        var line_iterator = std.mem.splitSequence(u8, response, "\r\n");
        while (line_iterator.next()) |line| {
            if (line.len > 0) {
                try lines.append(self.allocator, line);
            }
        }

        if (lines.items.len < 2) {
            return error.InvalidResponse;
        }

        // Check first line for success (should be '00, "", 1')
        const first_line = lines.items[0];
        var parts = std.mem.splitScalar(u8, first_line, ',');
        const status_code = parts.next() orelse return error.InvalidResponse;

        if (!std.mem.eql(u8, status_code, "00")) {
            return error.DeviceError;
        }

        // Parse second line (actual data)
        const data_line = lines.items[1];
        var data_parts = std.ArrayList([]const u8){};
        var data_iterator = std.mem.splitScalar(u8, data_line, ',');
        while (data_iterator.next()) |part| {
            try data_parts.append(self.allocator, part);
        }

        return data_parts.toOwnedSlice(self.allocator);
    }

    /// Get the current player state (for debugging/monitoring)
    pub fn getState(self: *Self) BlurayPlayerState {
        return self.state;
    }

    /// Check if player is configured (has IP address)
    pub fn isConfigured(self: *Self) bool {
        return self.ip_address != null;
    }

    /// Get the configured IP address
    pub fn getIpAddress(self: *Self) ?[]const u8 {
        return self.ip_address;
    }

    /// Send a command to the Blu-ray player
    pub fn sendCommand(self: *Self, command: Command) !void {
        if (self.ip_address == null) {
            return error.NoIpAddress;
        }

        const url = try std.fmt.allocPrint(self.allocator, "http://{s}/WAN/dvdr/dvdr_ctrl.cgi", .{self.ip_address.?});
        defer self.allocator.free(url);

        const body_data = switch (command) {
            .Play => "cCMD_PLAY.x=100&cCMD_PLAY.y=100",
            .Stop => "cCMD_STOP.x=100&cCMD_STOP.y=100",
            .Pause => "cCMD_PAUSE.x=100&cCMD_PAUSE.y=100",
            .Next => "cCMD_NEXT.x=100&cCMD_NEXT.y=100",
            .Previous => "cCMD_PREV.x=100&cCMD_PREV.y=100",
            .Power => "cCMD_PWR.x=100&cCMD_PWR.y=100",
            .OpenClose => "cCMD_OP_CL.x=100&cCMD_OP_CL.y=100",
        };

        const response = self.sendHttpRequest(url, body_data) catch |err| switch (err) {
            error.HttpRequestFailed => {
                // Commands might fail if device is off, but that's expected
                return;
            },
            else => return err,
        };
        defer self.allocator.free(response);

        // Parse the response to check for success
        const parsed = self.parseResponse(response) catch {
            // Some commands might return data we can't parse, but that's ok
            return;
        };
        defer self.allocator.free(parsed);

        // Update our state after sending command by refreshing status
        // Wait a bit for the command to take effect
        // std.time.sleep(100 * std.time.ns_per_ms);
        // self.refreshState() catch {
        // If we can't refresh state, that's ok - will be updated on next call
        // };
    }
};
