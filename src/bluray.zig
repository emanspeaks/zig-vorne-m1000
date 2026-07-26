const std = @import("std");
const Io = std.Io;
const protocol = @import("protocol.zig");
const config = @import("config.zig");
const time = @import("time.zig");
const process_mgmt = @import("process_mgmt.zig");
const str_utils = @import("str_utils.zig");
const phase_lock = @import("phase_lock.zig");
const PollKind = phase_lock.PollKind;
const Mode = @import("mode.zig").Mode;
const cues = @import("cues.zig");
const webvtt = @import("webvtt.zig");
const Marquee = @import("marquee.zig").Marquee;

const Writer = std.Io.Writer;
const maxbufsz = str_utils.maxbufsz;

pub const PLAYCHAR = protocol.DLE ++ "P"; // ►
pub const PAUSECHAR = "\xba"; // ║
pub const STOPCHAR = protocol.DLE ++ "G"; // ■

/// How often the selected cue file is checked for edits. One `stat` per second
/// is nothing next to the HTTP polling already going on, and it makes the file
/// editable while a disc is running.
pub const CUE_STAT_INTERVAL_MS: i64 = 1000;

/// Longest the polling thread sleeps in one go. Only bounds how quickly it
/// notices a mode change; the poll cadence itself comes from the phase lock.
const POLL_THREAD_SLICE_MS: i64 = 50;

/// Ceiling on how long the display loop sleeps when it has nothing scheduled.
///
/// The two clocks on line 1 are woken for exactly: the loop sleeps until the
/// next real-time second or the next playback tick, whichever comes first. This
/// only bounds the latency of everything not modelled that way -- a scroll
/// step, a cue boundary, a mode change.
const DISPLAY_IDLE_SLICE_MS: i64 = 25;

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

    // Last content written to each line, so only a line that actually changed
    // is re-clocked out. At 19200 baud a full 20 column line costs about 17 ms
    // to transmit, and the playback second usually ticks while line 2 is
    // unchanged, so sending them separately halves the time between the tick
    // and the display catching up with it.
    var last_line1: [maxbufsz]u8 = undefined;
    var last_line2: [maxbufsz]u8 = undefined;
    var have_last = false;

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

    // Sweeps line 2 back and forth when the message is wider than the display.
    var scroller: Marquee = .{};

    // The player is polled on its own thread. It must not happen here: a poll
    // costs a round trip, and the phase lock deliberately schedules its polls
    // either side of the player's tick edge, which is exactly the instant this
    // loop needs to be redrawing. Polling inline made every tick land a round
    // trip late no matter how accurate the lock itself was.
    var cell: SnapshotCell = .{};
    var stop_poller = std.atomic.Value(bool).init(false);
    const poller = try std.Thread.spawn(.{}, pollLoop, .{ io, allocator, &cell, &stop_poller });
    defer {
        stop_poller.store(true, .release);
        poller.join();
    }

    while (true) {
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

        // One clock reading for the whole frame, so the cue-file check and the
        // scroll position cannot disagree about what "now" is.
        const now_ms = time.nowMillis(io);

        // Read the player's published state and evaluate it for *now*, rather
        // than using a value that was current whenever the last poll happened.
        const snap = cell.read();
        playtime = snap.playTimeSeconds(now_ms);
        const playtime_hms = time.timedeltaToHms(playtime);
        const playtime_str = time.formatHms(playtime_hms, &playtime_buf) catch unreachable;
        const runstatus_str = switch (snap.run_status) {
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
        // A warning cue is pinned rather than swept: it has to be readable the
        // instant it appears, not a sweep later.
        var may_scroll = true;
        const line2: []const u8 = if (cue_state.isArmed()) blk: {
            // A stopped player has no meaningful position. A paused one holds
            // its last position, so the cue on screen stays put, which is what
            // you want when someone pauses mid-message.
            if (snap.run_status == .Stopped) break :blk "";
            const list = cue_list orelse break :blk "";
            const cue = list.at(snap.playTimeMillis(now_ms)) orelse break :blk "";
            may_scroll = cue.scroll;
            break :blk cue.text;
        } else if (loaded_name_len > 0)
            // Disarmed: show which file is loaded, so it is obvious the right
            // one was picked before starting the disc.
            cues.baseName(name_buf[0..loaded_name_len])
        else
            "Blu-Ray mode";

        const line2_window = if (may_scroll)
            scroller.window(line2, str_utils.maxchars, now_ms)
        else
            line2[0..@min(line2.len, str_utils.maxchars)];

        try str_utils.copyLeftJustify(&line2buf, line2_window, @min(line2_window.len, 20), null);

        // Send only the lines that actually changed. The playback second and
        // the time of day tick at unrelated moments, and line 2 usually does
        // not change at all, so redrawing everything would put a whole extra
        // line of serial traffic between the tick and the display showing it.
        if (!have_last or !std.mem.eql(u8, &linebuf, &last_line1)) {
            try protocol.appendStrToCmdList(allocator, &cmd_parts, 1, 1, &linebuf);
        }
        if (!have_last or !std.mem.eql(u8, &line2buf, &last_line2)) {
            try protocol.appendStrToCmdList(allocator, &cmd_parts, 2, 1, &line2buf);
        }

        if (cmd_parts.items.len > 0) {
            protocol.sendUnitDisplayCmd(allocator, port, 1, cmd_parts.items) catch |err| return err;
            last_line1 = linebuf;
            last_line2 = line2buf;
            have_last = true;
        }

        // Sleep until the next moment something on the display is due to
        // change: the next playback tick, or the next real-time second. Waking
        // on a fixed grid instead would quantise every tick to the grid period,
        // which is exactly the lateness this loop exists to avoid.
        var wake_ms = now_ms + DISPLAY_IDLE_SLICE_MS;
        if (snap.nextTickMs(now_ms)) |tick_ms| wake_ms = @min(wake_ms, tick_ms);
        const next_second_ms = (@divFloor(now_ms, 1000) + 1) * 1000;
        wake_ms = @min(wake_ms, next_second_ms);

        const sleep_ms = wake_ms - time.nowMillis(io);
        if (sleep_ms > 0) try io.sleep(.fromMilliseconds(sleep_ms), .awake);
    }
}

pub const BlurayPlayerRunStatus = enum {
    Stopped,
    Playing,
    Paused,
};

/// Everything the display needs to know about the player, in a form it can
/// evaluate for any instant without touching the network.
///
/// This is the whole point of the split. A poll costs a round trip, and the
/// polls that matter most are deliberately scheduled right next to the player's
/// tick edge -- which is exactly when the display needs to be redrawing. Poll
/// inline and every tick is redrawn a round trip late, which no amount of
/// phase-lock accuracy can make up for. So the polling thread publishes this,
/// and the display loop evaluates it at the moment it actually draws.
pub const Snapshot = struct {
    run_status: BlurayPlayerRunStatus = .Stopped,
    /// Last value the player actually reported.
    play_time_seconds: u32 = 0,
    /// Phase-lock anchor. The rest is meaningful only when `has_anchor`.
    ///
    /// This deliberately tracks whether an anchor *exists*, not whether its
    /// phase is currently trusted. The clock has to keep running while the lock
    /// hunts for a fresh bracket; falling back to the raw value there would
    /// stall the display until the next poll landed and then jump.
    has_anchor: bool = false,
    anchor_ms: i64 = 0,
    anchor_sec: u32 = 0,

    /// Play position in milliseconds at `now_ms`.
    pub fn playTimeMillis(self: Snapshot, now_ms: i64) i64 {
        if (self.run_status != .Playing or !self.has_anchor) {
            return @as(i64, self.play_time_seconds) * std.time.ms_per_s;
        }
        return @as(i64, self.anchor_sec) * std.time.ms_per_s + (now_ms - self.anchor_ms);
    }

    /// The whole second the player is showing at `now_ms`.
    pub fn playTimeSeconds(self: Snapshot, now_ms: i64) u32 {
        const ms = self.playTimeMillis(now_ms);
        if (ms <= 0) return 0;
        return @intCast(@divFloor(ms, std.time.ms_per_s));
    }

    /// When the displayed second next changes, or null when nothing is ticking
    /// and so there is no future moment worth waking up for.
    pub fn nextTickMs(self: Snapshot, now_ms: i64) ?i64 {
        if (self.run_status != .Playing or !self.has_anchor) return null;
        return self.anchor_ms + (@divFloor(now_ms - self.anchor_ms, 1000) + 1) * 1000;
    }
};

/// Hands a `Snapshot` from the polling thread to the display loop.
///
/// A spin lock, for the same reason as in `cues.zig`: the critical section is a
/// copy of a handful of words, and `std.Thread.Mutex` does not exist in 0.16.
const SnapshotCell = struct {
    guard: std.atomic.Value(bool) = .init(false),
    value: Snapshot = .{},

    fn acquire(self: *SnapshotCell) void {
        while (self.guard.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn release(self: *SnapshotCell) void {
        self.guard.store(false, .release);
    }

    fn publish(self: *SnapshotCell, value: Snapshot) void {
        self.acquire();
        defer self.release();
        self.value = value;
    }

    fn read(self: *SnapshotCell) Snapshot {
        self.acquire();
        defer self.release();
        return self.value;
    }
};

/// Poll the player on its own thread, publishing each result for the display.
///
/// Runs until `stop` is set. Sleeps in short slices rather than straight
/// through to the next poll so that a mode change is noticed promptly.
fn pollLoop(
    io: Io,
    allocator: std.mem.Allocator,
    cell: *SnapshotCell,
    stop: *std.atomic.Value(bool),
) void {
    var player = BlurayPlayer.init(io, allocator);
    defer player.deinit();

    while (!stop.load(.acquire)) {
        player.poll();
        cell.publish(player.snapshot());

        const now_ms = time.nowMillis(io);
        const wait_ms = @min(player.lock.next_poll_ms - now_ms, POLL_THREAD_SLICE_MS);
        if (wait_ms > 0) {
            io.sleep(.fromMilliseconds(wait_ms), .awake) catch return;
        }
    }
}

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

    // The poll cadence is owned entirely by `phase_lock.zig`; tune it there.

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

    /// Current state in the form the display consumes.
    ///
    /// The player reports whole seconds only, and each poll costs a network
    /// round trip, so the raw value is inherently stale. Once the phase of the
    /// player's 1 Hz tick is known, the displayed second can be computed from
    /// our own clock and will flip at the same instant the player's does -- but
    /// that computation belongs wherever the drawing happens, not here, so what
    /// is published is the anchor rather than a value read at poll time.
    pub fn snapshot(self: *const Self) Snapshot {
        return .{
            .run_status = self.state.run_status,
            .play_time_seconds = self.state.play_time_seconds,
            .has_anchor = self.lock.hasAnchor(),
            .anchor_ms = self.lock.anchor_ms,
            .anchor_sec = self.lock.anchor_sec,
        };
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

        // Playback just (re)started. The counter resumes at an unrelated phase
        // and possibly an unrelated position, so the old anchor is void rather
        // than merely untrusted.
        if (!was_playing) self.lock.reset();

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

test "a locked snapshot ticks with the player, not with when it was polled" {
    // Anchor: the player showed second 100 at t = 50_000.
    const snap: Snapshot = .{
        .run_status = .Playing,
        .play_time_seconds = 100,
        .has_anchor = true,
        .anchor_ms = 50_000,
        .anchor_sec = 100,
    };

    // The value advances with the local clock between polls...
    try std.testing.expectEqual(@as(u32, 100), snap.playTimeSeconds(50_000));
    try std.testing.expectEqual(@as(u32, 100), snap.playTimeSeconds(50_999));
    // ...and flips exactly on the player's own edge, not a moment later.
    try std.testing.expectEqual(@as(u32, 101), snap.playTimeSeconds(51_000));
    try std.testing.expectEqual(@as(u32, 107), snap.playTimeSeconds(57_400));

    // Millisecond position is what cue timing runs off.
    try std.testing.expectEqual(@as(i64, 100_400), snap.playTimeMillis(50_400));
}

test "nextTickMs is the instant the display must be redrawn" {
    const snap: Snapshot = .{
        .run_status = .Playing,
        .play_time_seconds = 100,
        .has_anchor = true,
        .anchor_ms = 50_000,
        .anchor_sec = 100,
    };

    // Waking here is what keeps the redraw on the player's edge rather than on
    // whatever grid the loop would otherwise have used.
    try std.testing.expectEqual(@as(?i64, 51_000), snap.nextTickMs(50_000));
    try std.testing.expectEqual(@as(?i64, 51_000), snap.nextTickMs(50_999));
    try std.testing.expectEqual(@as(?i64, 52_000), snap.nextTickMs(51_000));

    // Nothing is ticking when paused or stopped, so there is nothing to wake
    // for and the loop should fall back to its idle slice.
    var paused = snap;
    paused.run_status = .Paused;
    try std.testing.expectEqual(@as(?i64, null), paused.nextTickMs(50_500));

    // An unlocked snapshot cannot predict an edge either.
    var unlocked = snap;
    unlocked.has_anchor = false;
    try std.testing.expectEqual(@as(?i64, null), unlocked.nextTickMs(50_500));
}

test "an unlocked or paused snapshot falls back to the last reported second" {
    const paused: Snapshot = .{
        .run_status = .Paused,
        .play_time_seconds = 1234,
        .has_anchor = true,
        .anchor_ms = 50_000,
        .anchor_sec = 100,
    };
    // A paused player holds its position however much wall time passes.
    try std.testing.expectEqual(@as(u32, 1234), paused.playTimeSeconds(50_000));
    try std.testing.expectEqual(@as(u32, 1234), paused.playTimeSeconds(999_000));

    const searching: Snapshot = .{
        .run_status = .Playing,
        .play_time_seconds = 77,
        .has_anchor = false,
    };
    try std.testing.expectEqual(@as(u32, 77), searching.playTimeSeconds(123_456));
}

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
