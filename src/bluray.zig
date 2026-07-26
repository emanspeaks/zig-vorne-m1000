const std = @import("std");
const Io = std.Io;
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

pub fn runBlurayClocks(io: Io, allocator: std.mem.Allocator, port: anytype, mode: *std.atomic.Value(Mode)) !void {
    std.debug.print("Starting Blu-Ray run mode...\n", .{});

    // Build the command string dynamically
    var cmd_parts = std.ArrayList(u8).empty;
    defer cmd_parts.deinit(allocator);

    // Last payload actually written to the display, so identical frames can be
    // skipped instead of re-clocking the same bytes out at 19200 baud.
    var last_cmd = std.ArrayList(u8).empty;
    defer last_cmd.deinit(allocator);

    var playtime_buf: [maxbufsz]u8 = undefined;
    var linebuf: [maxbufsz]u8 = undefined;
    var playtime: u32 = 0;

    // The loop runs fast so the displayed second flips close to the player's
    // own tick; it is a scheduler, not a redraw rate. Polling is rate limited
    // inside `player.poll()`, and identical frames are never written to the
    // display, so a high rate here costs neither HTTP requests nor serial
    // traffic.
    var timer = frame_timer.FrameTimer.init(io, 20);

    // Initialize Blu-ray player
    var player = BlurayPlayer.init(io, allocator);
    defer player.deinit();

    // Load configuration from JSON
    const bluray_config = config.loadBlurayConfig(io, allocator);

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
        cmd_parts.clearRetainingCapacity();
        try str_utils.clearVorneLineBuf(&linebuf);

        // Get current local timestamp
        // const utc_timestamp = std.time.timestamp();

        // calculate total running time
        player.poll();
        playtime = player.playTime();
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

        if (cmd_parts.items.len > 0 and !std.mem.eql(u8, cmd_parts.items, last_cmd.items)) {
            protocol.sendUnitDisplayCmd(allocator, port, 1, cmd_parts.items) catch |err| return err;
            last_cmd.clearRetainingCapacity();
            try last_cmd.appendSlice(allocator, cmd_parts.items);
        }

        // Handle frame timing and sleep
        try timer.frameEnd();
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

/// Client for a Panasonic DP-UB820-K.
///
/// This is Panasonic's legacy LAN control interface rather than a modern REST
/// API: every request is a form-encoded POST to `/WAN/dvdr/dvdr_ctrl.cgi`, and
/// the player rejects requests that do not carry the `MEI-LAN-REMOTE-CALL`
/// user agent (MEI = Matsushita Electric Industrial). Responses are CRLF
/// separated plain text, not JSON. See `parseResponse` for the layout.
/// Whether we know the phase of the player's 1 Hz clock.
const PhaseLock = enum { searching, locked };

pub const BlurayPlayer = struct {
    io: Io,
    allocator: std.mem.Allocator,
    ip_address: ?[]const u8,
    state: BlurayPlayerState,
    last_update_time: i64,
    http_client: std.http.Client,

    // --- Phase lock on the player's 1 Hz tick (see `recordSample`) ---
    phase: PhaseLock,
    /// Wall-clock ms at which the play time became `anchor_sec`.
    anchor_ms: i64,
    anchor_sec: u32,
    /// Half-width of the bracket that produced `anchor_ms`, in ms. Smaller is
    /// a better estimate; used to decide whether a new edge is worth adopting.
    anchor_err_ms: i64,
    /// When the current lock was established, so it can be refreshed to
    /// counter any slow drift between the player's clock and ours.
    locked_at_ms: i64,
    /// Previous sample, used to bracket an edge.
    prev_sample_ms: i64,
    prev_sample_sec: u32,
    have_prev_sample: bool,
    /// Wall-clock ms at which the next poll is due.
    next_poll_ms: i64,

    const Self = @This();
    /// Required by the DP-UB820-K; the CGI returns an error without it.
    const USER_AGENT = "MEI-LAN-REMOTE-CALL";

    /// Poll cadence while hunting for a tick edge. Each edge is bracketed to
    /// roughly half this, which is far below what the display can show.
    const FAST_POLL_MS: i64 = 100;
    /// Once locked, a single confirmation poll shortly after each predicted
    /// edge is enough to notice a seek, pause or stop.
    const LOCK_CONFIRM_OFFSET_MS: i64 = 150;
    /// Cadence when the player is not playing (nothing is ticking).
    const IDLE_POLL_MS: i64 = 1000;
    /// Back off after a failed request rather than hammering the player.
    const ERROR_RETRY_MS: i64 = 2000;
    /// Re-hunt the edge occasionally so the lock cannot drift indefinitely.
    const RELOCK_INTERVAL_MS: i64 = 120_000;

    /// Initialize a new BlurayPlayer instance
    pub fn init(io: Io, allocator: std.mem.Allocator) Self {
        var ip_address = config.loadBlurayIp(io, allocator);
        if (ip_address) |ip| {
            ip_address = std.mem.trimEnd(u8, ip, "\r\n");
        }

        return Self{
            .io = io,
            .allocator = allocator,
            .ip_address = ip_address,
            .state = BlurayPlayerState.init(),
            .last_update_time = 0,
            .http_client = std.http.Client{ .allocator = allocator, .io = io },
            .phase = .searching,
            .anchor_ms = 0,
            .anchor_sec = 0,
            .anchor_err_ms = 0,
            .locked_at_ms = 0,
            .prev_sample_ms = 0,
            .prev_sample_sec = 0,
            .have_prev_sample = false,
            .next_poll_ms = 0,
        };
    }

    /// Cleanup resources
    pub fn deinit(self: *Self) void {
        self.http_client.deinit();
        if (self.ip_address) |ip| {
            self.allocator.free(ip);
        }
    }

    /// Poll the player if a poll is currently due. Cheap to call every frame:
    /// the cadence is decided internally, so the render loop can run fast
    /// without generating one HTTP request per frame.
    pub fn poll(self: *Self) void {
        const now = time.nowMillis(self.io);
        if (now < self.next_poll_ms) return;

        // Never trust a lock forever; the player's clock and ours are free
        // running and could slowly diverge.
        if (self.phase == .locked and now - self.locked_at_ms > RELOCK_INTERVAL_MS) {
            self.unlock();
        }

        self.getStatus() catch |err| {
            std.debug.print("Failed to get Blu-ray status: {}\n", .{err});
            self.next_poll_ms = now + ERROR_RETRY_MS;
            self.have_prev_sample = false;
            return;
        };
        self.scheduleNextPoll(time.nowMillis(self.io));
    }

    /// Current play time in seconds, extrapolated from the phase lock.
    ///
    /// The player reports whole seconds only, and each poll costs a network
    /// round trip, so the raw value is inherently stale. Once the phase of the
    /// player's 1 Hz tick is known, the displayed second can be computed from
    /// our own clock and will flip at the same instant the player's does.
    pub fn playTime(self: *Self) u32 {
        if (self.state.run_status != .Playing) return self.state.play_time_seconds;
        return self.predictAt(time.nowMillis(self.io));
    }

    fn predictAt(self: *Self, at_ms: i64) u32 {
        if (self.phase != .locked) return self.state.play_time_seconds;
        const elapsed_ms = at_ms - self.anchor_ms;
        if (elapsed_ms < 0) return self.anchor_sec;
        return self.anchor_sec +| @as(u32, @intCast(@divFloor(elapsed_ms, 1000)));
    }

    fn unlock(self: *Self) void {
        self.phase = .searching;
        self.anchor_err_ms = 0;
    }

    /// Fold one status sample into the phase lock.
    ///
    /// `sample_ms` is our best estimate of when the player read its own clock.
    /// When the reported second differs from the previous sample's, the
    /// increment must have happened between the two sample instants, so the
    /// midpoint of that bracket estimates the tick edge to within half the
    /// sampling gap. Polling quickly narrows the bracket; once it is tight the
    /// cadence drops to one confirmation poll per second.
    fn recordSample(self: *Self, sample_ms: i64, run_status: BlurayPlayerRunStatus, play_time: u32) void {
        const was_playing = self.state.run_status == .Playing;
        self.state.run_status = run_status;

        if (run_status != .Playing) {
            // Nothing is ticking; hold the reported value as-is.
            self.state.play_time_seconds = play_time;
            self.unlock();
            self.have_prev_sample = false;
            return;
        }

        // Playback just (re)started, so any previous phase is meaningless.
        if (!was_playing) {
            self.unlock();
            self.have_prev_sample = false;
        }

        // A reported value that disagrees with the prediction means the
        // timeline moved under us: a seek, or a lock that has gone stale.
        if (self.phase == .locked) {
            const drift = @as(i64, play_time) - @as(i64, self.predictAt(sample_ms));
            if (drift < -1 or drift > 1) {
                self.unlock();
                self.have_prev_sample = false;
            }
        }

        if (self.have_prev_sample and play_time != self.prev_sample_sec) {
            const err_ms = @divFloor(sample_ms - self.prev_sample_ms, 2);
            // Adopt only a strictly better estimate, so the coarse brackets
            // produced by once-a-second confirmation polls cannot degrade a
            // tight lock obtained during a fast hunt.
            if (self.phase != .locked or err_ms <= self.anchor_err_ms) {
                self.anchor_ms = self.prev_sample_ms + err_ms;
                self.anchor_sec = play_time;
                self.anchor_err_ms = err_ms;
                self.phase = .locked;
                self.locked_at_ms = sample_ms;
            }
        }

        self.state.play_time_seconds = play_time;
        self.prev_sample_ms = sample_ms;
        self.prev_sample_sec = play_time;
        self.have_prev_sample = true;
    }

    fn scheduleNextPoll(self: *Self, now: i64) void {
        if (self.state.run_status != .Playing) {
            self.next_poll_ms = now + IDLE_POLL_MS;
            return;
        }
        if (self.phase != .locked) {
            self.next_poll_ms = now + FAST_POLL_MS;
            return;
        }
        // Locked: land just after the next predicted edge, which both confirms
        // the lock and bounds how long a seek can go unnoticed, at ~1 poll/sec.
        const k = @divFloor(now - self.anchor_ms, 1000) + 1;
        self.next_poll_ms = self.anchor_ms + k * 1000 + LOCK_CONFIRM_OFFSET_MS;
    }

    /// Internal method to update player state from the actual device
    fn getStatus(self: *Self) !void {
        if (self.ip_address == null) {
            return error.NoIpAddress;
        }

        const url = try std.fmt.allocPrint(self.allocator, "http://{s}/WAN/dvdr/dvdr_ctrl.cgi", .{self.ip_address.?});
        defer self.allocator.free(url);

        // `cCMD_PST` is accepted without the SHA-256 authentication that the
        // richer `cCMD_REVIEW` status query requires, so a poll costs exactly
        // one round trip with no nonce fetch.
        const body_data = "cCMD_PST.x=100&cCMD_PST.y=100";
        const sent_ms = time.nowMillis(self.io);
        const response = self.sendHttpRequest(url, body_data) catch |err| switch (err) {
            error.HttpRequestFailed => {
                self.state.is_off = true;
                return;
            },
            else => return err,
        };
        defer self.allocator.free(response);
        const recv_ms = time.nowMillis(self.io);
        // The player read its own clock somewhere inside the request window.
        // The midpoint is the least-biased estimate; timestamping on arrival
        // would bias every sample late by roughly a full round trip.
        const sample_ms = sent_ms + @divFloor(recv_ms - sent_ms, 2);

        const parsed = self.parseResponse(response) catch |err| {
            return err;
        };
        defer self.allocator.free(parsed);

        if (parsed.len >= 4) {
            // Second line of the response, comma separated:
            //   0: transport state (0 stopped / 1 playing / 2 paused)
            //   1: elapsed play time in whole seconds (-2 => no disc)
            //   2, 3: purpose unknown; field 3 is an 8 digit hex-looking value
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
                self.recordSample(sample_ms, play_state, play_time);
            } else {
                self.recordSample(sample_ms, .Stopped, 0);
                self.state.is_standby = true; // No disc or deep standby
            }

            self.state.is_standby = play_state == .Stopped;
            self.state.is_off = false;
        }
    }

    /// Send HTTP request to the Blu-ray player
    fn sendHttpRequest(self: *Self, url: []const u8, body: []const u8) ![]u8 {
        // Use Writer.Allocating for collecting HTTP response data
        var allocating_writer = std.Io.Writer.Allocating.init(self.allocator);
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
        var lines = std.ArrayList([]const u8).empty;
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
        var data_parts = std.ArrayList([]const u8).empty;
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
