const std = @import("std");
const Io = std.Io;
const protocol = @import("protocol.zig");
const config = @import("config.zig");
const time = @import("time.zig");
const process_mgmt = @import("process_mgmt.zig");
const str_utils = @import("str_utils.zig");
const frame_timer = @import("frame_timer.zig");
const phase_lock = @import("phase_lock.zig");
const PollKind = phase_lock.PollKind;
const Mode = @import("mode.zig").Mode;
const cues = @import("cues.zig");
const webvtt = @import("webvtt.zig");

const Writer = std.Io.Writer;
const maxbufsz = str_utils.maxbufsz;

pub const PLAYCHAR = protocol.DLE ++ "P"; // ►
pub const PAUSECHAR = "\xba"; // ║
pub const STOPCHAR = protocol.DLE ++ "G"; // ■

/// How often the selected cue file is checked for edits. One `stat` per second
/// is nothing next to the HTTP polling already going on, and it makes the file
/// editable while a disc is running.
pub const CUE_STAT_INTERVAL_MS: i64 = 1000;

pub fn runBlurayClocks(
    io: Io,
    allocator: std.mem.Allocator,
    port: anytype,
    mode: *std.atomic.Value(Mode),
    cue_state: *cues.State,
) !void {
    std.debug.print("Starting Blu-Ray run mode...\n", .{});

    // Build the command string dynamically
    var cmd_parts = std.ArrayList(u8).empty;
    defer cmd_parts.deinit(allocator);

    // Last payload actually written to the display, so identical frames can be
    // skipped instead of re-clocking the same bytes out at 19200 baud.
    var last_cmd = std.ArrayList(u8).empty;
    defer last_cmd.deinit(allocator);

    var playtime_buf: [maxbufsz]u8 = undefined;
    var clock_buf: [maxbufsz]u8 = undefined;
    var linebuf: [maxbufsz]u8 = undefined;
    var line2buf: [maxbufsz]u8 = undefined;
    var playtime: u32 = 0;

    // Time of day, shown at the left of line 1. Owns the cached zone offset.
    var clock = time.LocalClock.init(io);

    // Line 2 comes from the cue file chosen on the web page. It is reloaded
    // when the selection changes -- which `generation` reports with a single
    // atomic load, cheap enough to check every frame -- and when the file
    // itself is edited, which costs one stat per second.
    var cue_list: ?webvtt.CueList = null;
    defer if (cue_list) |list| list.deinit();
    var loaded_generation: u64 = 0;
    var name_buf: [cues.max_name_len]u8 = undefined;
    var loaded_name_len: usize = 0;
    var loaded_print: ?cues.Fingerprint = null;
    var next_stat_ms: i64 = 0;

    // The loop runs fast so the displayed second flips close to the player's
    // own tick; it is a scheduler, not a redraw rate. Polling is rate limited
    // inside `player.poll()`, and identical frames are never written to the
    // display, so a high rate here costs neither HTTP requests nor serial
    // traffic.
    var timer = frame_timer.FrameTimer.init(io, 20);

    // Initialize Blu-ray player
    var player = BlurayPlayer.init(io, allocator);
    defer player.deinit();

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
        clock_buf = undefined;
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

        // Line 1: time of day at the left, elapsed play time and transport
        // state at the right.
        //
        // The width passed here is the string's own length, not the width of
        // the field it sits in: `copyLeftJustify` pads a wider field by
        // shifting the rest of the line right, which would push the line past
        // 20 columns. `clearVorneLineBuf` already blanked the gap.
        const clock_str = clock.formatNow(io, &clock_buf) catch unreachable;
        try str_utils.copyLeftJustify(&linebuf, clock_str, @min(clock_str.len, 20 -| playtime_str.len), null);
        try str_utils.copyRightJustify(&linebuf, playtime_str, @min(playtime_str.len, 20), 1);
        try str_utils.copyRightJustify(&linebuf, runstatus_str, 1, 0);
        try protocol.appendStrToCmdList(allocator, &cmd_parts, 1, 1, &linebuf);

        // Pick up a cue file the moment the web page selects a different one,
        // and pick up edits to the file that is already showing.
        const generation = cue_state.generation.load(.acquire);
        const selection_changed = generation != loaded_generation;
        if (selection_changed) {
            loaded_generation = generation;
            if (cue_list) |list| list.deinit();
            cue_list = null;
            loaded_print = null;
            loaded_name_len = 0;
            next_stat_ms = 0;
            if (cue_state.currentName(&name_buf)) |name| loaded_name_len = name.len;
        }

        if (loaded_name_len > 0) {
            const now_ms = time.nowMillis(io);
            if (now_ms >= next_stat_ms) {
                next_stat_ms = now_ms + CUE_STAT_INTERVAL_MS;
                const name = name_buf[0..loaded_name_len];

                // A file that cannot be stat'ed -- deleted, or a temporary
                // being renamed into place by an editor -- is left alone. The
                // next check picks it up, and the cues already in memory beat a
                // blank line in the meantime.
                if (cues.fingerprint(io, name)) |current| {
                    // Load on the first pass, and thereafter only when the file
                    // has actually changed on disk, so editing it while a disc
                    // is running takes effect within a second.
                    const stale = if (loaded_print) |previous| !previous.eql(current) else true;
                    if (stale) {
                        if (cues.load(io, allocator, name)) |fresh| {
                            if (cue_list) |list| list.deinit();
                            cue_list = fresh;
                        } else |err| {
                            // Keep whatever was already on screen: a briefly
                            // broken file is normal while editing, and blanking
                            // line 2 mid-movie over a typo is worse than
                            // showing stale cues until the next save.
                            std.debug.print("Failed to load cue file {s}: {}\n", .{ name, err });
                        }
                        // Recorded either way, so a file that fails to parse is
                        // not re-read every second until it is saved again.
                        loaded_print = current;
                    }
                }
            }
        }

        // Line 2: the message due at the current play position, but only once
        // armed from the web page. Nothing about the player's status can tell
        // us the feature is running rather than a menu or a trailer, so the
        // decision is the operator's.
        try str_utils.clearVorneLineBuf(&line2buf);
        const line2: []const u8 = if (cue_state.isArmed()) blk: {
            // A stopped player has no meaningful position. A paused one holds
            // its last position, so the cue on screen stays put, which is what
            // you want when someone pauses mid-message.
            if (player.state.run_status == .Stopped) break :blk "";
            const list = cue_list orelse break :blk "";
            break :blk list.textAt(player.playTimeMillis()) orelse "";
        } else if (loaded_name_len > 0)
            // Disarmed: show which file is loaded, so it is obvious the right
            // one was picked before starting the disc.
            cues.baseName(name_buf[0..loaded_name_len])
        else
            "Blu-Ray mode";

        try str_utils.copyLeftJustify(&line2buf, line2, @min(line2.len, 20), null);
        try protocol.appendStrToCmdList(allocator, &cmd_parts, 2, 1, &line2buf);

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

/// Commands that can be sent to the Blu-ray player.
///
/// UHD (UB-series) players use the `RC_*` remote-key codes below. The older
/// BD-series codes (`cCMD_PLAY`, `cCMD_PWR`, ...) are *not* accepted by a
/// DP-UB820-K. Codes taken from the command table in `ha-panasonic_ub`.
pub const Command = enum {
    Play,
    Stop,
    Pause,
    Next,
    Previous,
    PowerOn,
    PowerOff,
    OpenClose,

    /// The protocol code, i.e. the `<CODE>` in `cCMD_<CODE>.x=100&...`.
    pub fn code(self: Command) []const u8 {
        return switch (self) {
            .Play => "RC_PLAYBACK",
            .Stop => "RC_STOP",
            .Pause => "RC_PAUSE",
            .Next => "RC_SKIPFWD",
            .Previous => "RC_SKIPREV",
            .PowerOn => "RC_POWERON",
            .PowerOff => "RC_POWEROFF",
            .OpenClose => "RC_OP_CL",
        };
    }
};

/// Client for a Panasonic DP-UB820-K.
///
/// This is Panasonic's legacy LAN control interface rather than a modern REST
/// API: every request is a form-encoded POST to `/WAN/dvdr/dvdr_ctrl.cgi`, and
/// the player rejects requests that do not carry the `MEI-LAN-REMOTE-CALL`
/// user agent (MEI = Matsushita Electric Industrial). Responses are CRLF
/// separated plain text, not JSON. See `parseResponse` for the layout.
pub const BlurayPlayer = struct {
    io: Io,
    allocator: std.mem.Allocator,
    ip_address: ?[]const u8,
    /// 32-character control-API key, or null to run unauthenticated. Status
    /// polling works either way; control commands require it on stock firmware.
    secret_key: ?[]const u8,
    state: BlurayPlayerState,
    last_update_time: i64,
    http_client: std.http.Client,

    /// Tracks the phase of the player's 1 Hz tick so the displayed time can be
    /// interpolated from the local clock between polls, and decides the poll
    /// cadence. See `phase_lock.zig`.
    lock: phase_lock.PhaseLock,

    const Self = @This();
    /// Required by the DP-UB820-K; the CGI returns an error without it.
    const USER_AGENT = "MEI-LAN-REMOTE-CALL";
    /// Arbitrary client identifier sent when requesting a nonce.
    const AUTH_SID = "VORNE_M1000";
    /// Number of leading key characters echoed in `cAUTH_FORM`. Observed as 2
    /// on a UB-series player (`cAUTH_FORM=C4`); openHAB uses 3 for some keys,
    /// so this may need to become key-dependent if a key ever fails to work.
    const AUTH_FORM_LEN = 2;

    /// Poll cadence while hunting for a tick edge. Each edge is bracketed to
    /// roughly half this, which is far below what the display can show.
    const FAST_POLL_MS: i64 = 100;
    /// Half-width of the straddle window placed around each predicted edge.
    /// Also the largest phase error the lock will tolerate before re-hunting.
    const EDGE_GUARD_MS: i64 = 75;
    /// Cadence when the player is not playing. Kept short because the event we
    /// are waiting for is the transition back into playback, and every
    /// millisecond of delay noticing it is a millisecond of stale display.
    const IDLE_POLL_MS: i64 = 300;
    /// Back off after a failed request rather than hammering the player.
    const ERROR_RETRY_MS: i64 = 2000;

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
            .secret_key = config.loadBlurayKey(io, allocator),
            .state = BlurayPlayerState.init(),
            .last_update_time = 0,
            .http_client = std.http.Client{ .allocator = allocator, .io = io },
            .lock = .init,
        };
    }

    /// Cleanup resources
    pub fn deinit(self: *Self) void {
        self.http_client.deinit();
        if (self.ip_address) |ip| {
            self.allocator.free(ip);
        }
        if (self.secret_key) |key| {
            self.allocator.free(key);
        }
    }

    /// Poll the player if a poll is currently due. Cheap to call every frame:
    /// the cadence is decided by the phase lock, so the render loop can run
    /// fast without generating one HTTP request per frame.
    pub fn poll(self: *Self) void {
        const now = time.nowMillis(self.io);
        if (!self.lock.due(now)) return;

        const kind = self.lock.next_kind;
        self.getStatus(kind) catch |err| {
            std.debug.print("Failed to get Blu-ray status: {}\n", .{err});
            self.lock.retryAfterError(now);
            return;
        };
        self.lock.schedule(time.nowMillis(self.io), kind, self.state.run_status == .Playing);
    }

    /// Current play time in seconds, extrapolated from the phase lock.
    ///
    /// The player reports whole seconds only, and each poll costs a network
    /// round trip, so the raw value is inherently stale. Once the phase of the
    /// player's 1 Hz tick is known, the displayed second can be computed from
    /// our own clock and will flip at the same instant the player's does.
    pub fn playTime(self: *Self) u32 {
        if (self.state.run_status != .Playing) return self.state.play_time_seconds;
        return self.lock.predict(time.nowMillis(self.io), self.state.play_time_seconds);
    }

    /// Current play time in milliseconds.
    ///
    /// The player itself only ever reports whole seconds, but the phase lock
    /// knows where the second boundaries fall, so sub-second position comes for
    /// free once locked -- which is what cue timing wants, since a cue file has
    /// millisecond resolution. Falls back to the whole second when there is no
    /// lock to interpolate from.
    pub fn playTimeMillis(self: *Self) i64 {
        const seconds_ms = @as(i64, self.state.play_time_seconds) * std.time.ms_per_s;
        if (self.state.run_status != .Playing or !self.lock.isLocked()) return seconds_ms;
        return @as(i64, self.lock.anchor_sec) * std.time.ms_per_s +
            (time.nowMillis(self.io) - self.lock.anchor_ms);
    }

    /// Fold one status sample into the phase lock.
    ///
    /// `sample_ms` is the best estimate of when the player read its own clock.
    fn recordSample(self: *Self, sample_ms: i64, kind: PollKind, run_status: BlurayPlayerRunStatus, play_time: u32) void {
        const was_playing = self.state.run_status == .Playing;
        self.state.run_status = run_status;
        self.state.play_time_seconds = play_time;

        if (run_status != .Playing) {
            // Nothing is ticking, and resuming will restart the tick at an
            // unrelated phase, so the lock is void.
            self.lock.sampleStopped();
            return;
        }

        // Playback just (re)started; the previous phase means nothing now.
        if (!was_playing) self.lock.drop();

        self.lock.sampleRunning(sample_ms, kind, play_time);
    }

    /// Internal method to update player state from the actual device
    fn getStatus(self: *Self, kind: PollKind) !void {
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
                self.recordSample(sample_ms, kind, play_state, play_time);
            } else {
                self.recordSample(sample_ms, kind, .Stopped, 0);
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

    /// Fetch a one-shot challenge string for command authentication.
    ///
    /// Caller owns the returned buffer.
    fn fetchNonce(self: *Self) ![]u8 {
        const url = try std.fmt.allocPrint(self.allocator, "http://{s}/cgi-bin/get_nonce.cgi", .{self.ip_address.?});
        defer self.allocator.free(url);

        const raw = try self.sendHttpRequest(url, "SID=" ++ AUTH_SID);
        defer self.allocator.free(raw);

        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) return error.EmptyNonce;
        return self.allocator.dupe(u8, trimmed);
    }

    /// `cAUTH_VALUE` for a challenge: uppercase hex SHA-256 of key ++ nonce.
    fn authValue(key: []const u8, nonce: []const u8) [64]u8 {
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(key);
        hasher.update(nonce);
        hasher.final(&digest);
        return std.fmt.bytesToHex(digest, .upper);
    }

    /// Build the POST body for `command`, including authentication fields when
    /// a secret key is configured. Caller owns the returned buffer.
    ///
    /// Observed on the wire, for reference:
    ///   cCMD_RC_POWERON.x=100&cCMD_RC_POWERON.y=100&cAUTH_FORM=C4&cAUTH_VALUE=3C90...
    fn buildCommandBody(self: *Self, code: []const u8) ![]u8 {
        const key = self.secret_key orelse
            return std.fmt.allocPrint(self.allocator, "cCMD_{s}.x=100&cCMD_{s}.y=100", .{ code, code });

        const nonce = try self.fetchNonce();
        defer self.allocator.free(nonce);

        const auth = authValue(key, nonce);
        // `cAUTH_FORM` is the leading characters of the key, sent in the clear;
        // it appears to identify the key format.
        return std.fmt.allocPrint(
            self.allocator,
            "cCMD_{s}.x=100&cCMD_{s}.y=100&cAUTH_FORM={s}&cAUTH_VALUE={s}",
            .{ code, code, key[0..AUTH_FORM_LEN], auth[0..] },
        );
    }

    /// Send a command to the Blu-ray player
    pub fn sendCommand(self: *Self, command: Command) !void {
        if (self.ip_address == null) {
            return error.NoIpAddress;
        }

        const url = try std.fmt.allocPrint(self.allocator, "http://{s}/WAN/dvdr/dvdr_ctrl.cgi", .{self.ip_address.?});
        defer self.allocator.free(url);

        // Authenticated when a key is configured; the nonce round trip happens
        // inside `buildCommandBody`.
        const body_data = try self.buildCommandBody(command.code());
        defer self.allocator.free(body_data);

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

test "authValue is uppercase hex SHA-256 of key ++ nonce" {
    // SHA-256("ab"), i.e. key "a" concatenated with nonce "b".
    const expected = "FB8E20FC2E4C3F248C60C39BD652F3C1347298BB977B8B4D5903B85055620603";
    const actual = BlurayPlayer.authValue("a", "b");
    try std.testing.expectEqualStrings(expected, &actual);
    try std.testing.expectEqual(@as(usize, 64), actual.len);
}

test "command codes are the UB-series RC_* form" {
    // The older BD-series codes (cCMD_PLAY, cCMD_PWR) are rejected by UB players.
    try std.testing.expectEqualStrings("RC_PLAYBACK", Command.Play.code());
    try std.testing.expectEqualStrings("RC_POWERON", Command.PowerOn.code());
    try std.testing.expectEqualStrings("RC_OP_CL", Command.OpenClose.code());
}

test {
    // Force analysis of decls that nothing calls yet, such as the auth path.
    std.testing.refAllDecls(BlurayPlayer);
}
