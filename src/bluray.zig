const std = @import("std");
const Io = std.Io;
const protocol = @import("protocol.zig");
const config = @import("config.zig");
const time = @import("time.zig");
const process_mgmt = @import("process_mgmt.zig");
const str_utils = @import("str_utils.zig");
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
/// notices shutdown; the poll itself is otherwise back-to-back with the
/// player's own response time as the only throttle -- see `pollLoop`.
const POLL_THREAD_SLICE_MS: i64 = 50;

/// How often the cue thread checks the file and, less often, the timezone.
/// Also bounds how quickly it notices a mode change.
const CUE_THREAD_SLICE_MS: i64 = 200;

/// A render pass later than this past its scheduled wake is reported.
///
/// The display loop is treated as a real-time task: every wake exists because
/// something is due on screen at that instant, so being late is a defect rather
/// than a slow frame. Nothing on the loop should be able to cause one -- all
/// file and network I/O is on other threads -- which makes a report here a
/// signal that something has crept back on, or that the serial write is
/// colliding with the next deadline.
const DEADLINE_SLACK_MS: i64 = 12;

/// Ceiling on how long the display loop sleeps when it has nothing scheduled.
///
/// The two clocks on line 1 are woken for exactly: the loop sleeps until the
/// next real-time second or the next playback tick, whichever comes first. This
/// only bounds the latency of everything not modelled that way -- a scroll
/// step, a cue boundary, a mode change.
const DISPLAY_IDLE_SLICE_MS: i64 = 25;

/// How old a snapshot may be before its play position stops being trusted for
/// cue lookup. Long enough to ride out a couple of failed polls, short enough
/// that a message cannot sit on screen after playback has moved on.
const stale_position_ms: i64 = 2500;

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


    // Line 2 comes from the cue file chosen on the web page. The file is
    // watched and parsed on the cue thread; what arrives here is a ready-made
    // list, collected with one atomic load per frame.
    var cue_list: ?webvtt.CueList = null;
    defer if (cue_list) |list| list.deinit();

    // Sweeps line 2 back and forth when the message is wider than the display.
    var scroller: Marquee = .{};

    // The selected file's name, shown on line 2 while cues are disarmed.
    var name_buf: [cues.max_name_len]u8 = undefined;
    var name_len: usize = 0;
    var seen_generation: u64 = 0;

    // Everything that can block for an unbounded time runs on its own thread,
    // so that this loop only ever does arithmetic, a memcmp and one serial
    // write. It is a real-time task: each wake exists because something is due
    // on screen at that instant, and there is no catching up afterwards.
    //
    //   * the player is polled on `pollLoop`. A poll costs a round trip, and
    //     the loop dispatches the next one immediately after the previous
    //     response arrives -- no schedule to compute, just the player's own
    //     response time as the pace.
    //   * the cue file is watched and parsed on `cueLoop`, along with the
    //     timezone. Both are file I/O, and a cue file arrives whenever it
    //     happens to be saved.
    var cell: SnapshotCell = .{};
    var cue_cell: CueCell = .{};
    defer cue_cell.deinit();
    var zone: time.SharedZone = .init(time.getTimezoneInfo(io));

    var stop_workers = std.atomic.Value(bool).init(false);
    const poller = try std.Thread.spawn(.{}, pollLoop, .{ io, allocator, &cell, &stop_workers });
    const cue_thread = try std.Thread.spawn(.{}, cueLoop, .{ io, allocator, cue_state, &cue_cell, &zone, &stop_workers });
    defer {
        stop_workers.store(true, .release);
        poller.join();
        cue_thread.join();
    }

    // What the previous pass scheduled, so lateness can be reported.
    var due_ms: i64 = 0;
    var late_frames: u32 = 0;

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
        // Time of day, from the offset the cue thread keeps refreshed. Working
        // it out here would mean parsing `/etc/localtime` on a loop that has
        // deadlines to meet.
        const local_ms = now_ms + @as(i64, zone.load().offset_sec) * std.time.ms_per_s;
        const clock_str = time.formatClock(@divFloor(local_ms, std.time.ms_per_s), &clock_buf) catch unreachable;
        try str_utils.copyLeftJustify(&linebuf, clock_str, @min(clock_str.len, 20 -| playtime_str.len), null);
        try str_utils.copyRightJustify(&linebuf, playtime_str, @min(playtime_str.len, 20), 1);
        try str_utils.copyRightJustify(&linebuf, runstatus_str, 1, 0);

        // Collect a cue file the cue thread has finished parsing. One atomic
        // load on almost every pass; the pointer swap and the arena free only
        // happen when the selection changes or the file is edited.
        if (cue_cell.take()) |fresh| {
            if (cue_list) |list| list.deinit();
            cue_list = fresh;
            // Only fires on an actual transition (cueLoop publishes on load or
            // clear, not every pass), so this is safe at render-loop rate.
            if (cue_list) |list| {
                std.debug.print("bluray: display picked up {d} cues\n", .{list.cues.len});
            } else {
                std.debug.print("bluray: display cleared its cue list\n", .{});
            }
        }

        // The selected file's name, kept only to show while disarmed. Re-read
        // just when it changes, so the common pass takes no lock at all.
        const generation = cue_state.generation.load(.acquire);
        if (generation != seen_generation) {
            seen_generation = generation;
            name_len = 0;
            if (cue_state.currentName(&name_buf)) |name| name_len = name.len;
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
            // Only show a cue while the position it is keyed to is actually
            // being tracked. Stopped, paused, seeking, or simply not answering
            // all leave the position frozen at whatever the last poll returned,
            // and a frozen position pins whatever cue happened to cover it on
            // screen indefinitely -- which is exactly what happens when you
            // work the transport controls mid-message.
            if (!snap.positionIsLive(now_ms)) break :blk "";
            const list = cue_list orelse break :blk "";
            // Outside every cue's span the line is blank, checked afresh each
            // pass rather than left holding the last message.
            const cue = list.at(snap.playTimeMillis(now_ms)) orelse break :blk "";
            may_scroll = cue.scroll;
            break :blk cue.text;
        } else if (name_len > 0)
            // Disarmed: show which file is loaded, so it is obvious the right
            // one was picked before starting the disc.
            cues.baseName(name_buf[0..name_len])
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
        // change: the next real-time second, or the next scroll step. Waking
        // on a fixed grid instead would quantize each of them to the grid
        // period -- which for the clock is the lateness this loop exists to
        // avoid, and for the scroll is visible as stutter, since evenly
        // spaced steps are the whole of what makes a character-cell marquee
        // look smooth. The play-time second has no such schedule to compute:
        // it only ever changes when a fresh poll result arrives, which the
        // idle slice below picks up (and only redraws) within
        // `DISPLAY_IDLE_SLICE_MS` -- see `bluray.Snapshot`.
        var wake_ms = now_ms + DISPLAY_IDLE_SLICE_MS;
        // The displayed second flips on a local-time boundary. Offsets are
        // whole minutes, so that is also a UTC second boundary.
        const next_second_ms = (@divFloor(now_ms, 1000) + 1) * 1000;
        wake_ms = @min(wake_ms, next_second_ms);
        if (may_scroll) {
            if (scroller.nextStepMs(line2, str_utils.maxchars, now_ms)) |step_ms| {
                wake_ms = @min(wake_ms, step_ms);
            }
        }
        // Wake exactly when the next cue starts or the current one ends. The
        // warning cues are only a second long, so noticing them on some later
        // sample risks stepping over one entirely -- and a warning that never
        // appears is worse than one that appears a little late.
        if (cue_list) |list| {
            if (snap.positionIsLive(now_ms)) {
                const position_ms = snap.playTimeMillis(now_ms);
                if (list.nextBoundaryMs(position_ms)) |boundary_ms| {
                    wake_ms = @min(wake_ms, now_ms + (boundary_ms - position_ms));
                }
            }
        }

        // Report a pass that started noticeably after the instant it was
        // scheduled for. Every wake exists because something was due on screen
        // then, and there is no catching up afterwards -- a late pass is a
        // frame shown late, so it is a defect worth seeing in the log rather
        // than something to absorb quietly.
        if (due_ms != 0 and now_ms - due_ms > DEADLINE_SLACK_MS) {
            late_frames += 1;
            std.debug.print(
                "Display pass {d} ms late (deadline {d}, {d} so far)\n",
                .{ now_ms - due_ms, due_ms, late_frames },
            );
        }
        due_ms = wake_ms;

        const sleep_ms = wake_ms - time.nowMillis(io);
        if (sleep_ms > 0) try io.sleep(.fromMilliseconds(sleep_ms), .awake);
    }
}

pub const BlurayPlayerRunStatus = enum {
    Stopped,
    Playing,
    Paused,
};

/// Fixed, hand-tunable offset folded into the raw play position before it
/// reaches the display or drives cue timing.
///
/// The player's own report is shown as-is, with no interpolation between
/// polls -- see `Snapshot`. But there are latencies downstream of that report
/// that polling faster can never see: time spent in the player's own
/// decode/output pipeline, a TV or AVR's own processing delay, anything
/// between "the player's internal counter reached N" and a human seeing
/// second N appear on the screen. If the panel is observed to consistently
/// read behind what is actually playing, this is the knob: increase it in
/// small steps (50-100 ms at a time) while comparing the panel against the
/// picture, until they line up. A negative value pulls the display back
/// instead. Since the display only ever shows whole seconds, a lead smaller
/// than the remaining fraction of the current second has no visible effect
/// until it accumulates enough to cross a second boundary.
///
/// No principled default exists -- it depends on hardware this code cannot
/// see -- so it starts at zero.
///
/// Settable two ways, both funnelled through `setDisplayLead`: once at startup
/// from `display_lead_config_path`, and live from the web page. Because it can
/// now change at any moment on the HTTP thread while the display loop reads it
/// every frame, this is an atomic rather than a plain `var` -- unlike
/// `cues.active_dir_path`, which really is set once before any other thread
/// exists and stays that way.
pub var display_lead_ms: std.atomic.Value(i64) = .init(0);

pub const display_lead_config_path = "/home/emanspeaks/bluray_display_lead_ms.txt";

/// Parse a candidate lead value. Pure and I/O-free so the parsing itself is
/// directly testable; null for anything that is not a bare signed integer.
pub fn parseDisplayLeadConfig(raw: []const u8) ?i64 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(i64, trimmed, 10) catch null;
}

/// Read `display_lead_config_path` and, if it holds a valid integer, use it in
/// place of the built-in default for the rest of the process.
///
/// Call once, early in `main`, before the Blu-ray display loop starts. Unlike
/// `cues.configureDirPath`, this one does not need that ordering for
/// correctness -- `display_lead_ms` is safe to write from any thread at any
/// time -- but there is no reason to let the display run even briefly on the
/// stale default while this is read.
pub fn configureDisplayLead(io: Io) void {
    const raw = Io.Dir.readFileAlloc(
        .cwd(),
        io,
        display_lead_config_path,
        std.heap.page_allocator,
        .limited(64),
    ) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("No {s}, display_lead_ms stays {d}\n", .{ display_lead_config_path, display_lead_ms.load(.monotonic) });
            return;
        },
        else => {
            std.debug.print(
                "Error reading {s}: {}, display_lead_ms stays {d}\n",
                .{ display_lead_config_path, err, display_lead_ms.load(.monotonic) },
            );
            return;
        },
    };
    defer std.heap.page_allocator.free(raw);

    const parsed = parseDisplayLeadConfig(raw) orelse {
        std.debug.print(
            "{s} does not contain a plain integer, display_lead_ms stays {d}\n",
            .{ display_lead_config_path, display_lead_ms.load(.monotonic) },
        );
        return;
    };
    display_lead_ms.store(parsed, .release);
    std.debug.print("Using display_lead_ms = {d} ms\n", .{parsed});
}

/// Write `value` to `display_lead_config_path` so it survives a restart.
///
/// Best-effort: a write failure (read-only filesystem, full disk) is logged
/// and swallowed rather than propagated, since `setDisplayLead` has already
/// applied the value to the running process by the time this runs, and a
/// persistence failure should not make the live change look like it failed.
fn persistDisplayLead(io: Io, value: i64) void {
    persistDisplayLeadTo(io, display_lead_config_path, value);
}

/// `persistDisplayLead`, with the path passed explicitly. Split out so the
/// write itself is testable against a path guaranteed to be writable, rather
/// than against `display_lead_config_path`'s hardcoded directory, which need
/// not exist on every machine this is tested on (it does not, on the machine
/// this was developed on).
fn persistDisplayLeadTo(io: Io, path: []const u8, value: i64) void {
    var text_buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, "{d}\n", .{value}) catch unreachable;

    const file = Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
        std.debug.print("Failed to open {s} for writing: {}\n", .{ path, err });
        return;
    };
    defer file.close(io);

    var write_buf: [64]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    writer.interface.writeAll(text) catch |err| {
        std.debug.print("Failed to write {s}: {}\n", .{ path, err });
        return;
    };
    writer.interface.flush() catch |err| {
        std.debug.print("Failed to flush {s}: {}\n", .{ path, err });
    };
}

/// Apply a new lead value to the running process and persist it, so a change
/// made from the web page takes effect immediately and survives a restart.
/// This is the single entry point both `main.zig`'s `/display-lead` handler
/// and any future caller should use, rather than writing `display_lead_ms`
/// directly and forgetting the file, or vice versa.
pub fn setDisplayLead(io: Io, value: i64) void {
    display_lead_ms.store(value, .release);
    persistDisplayLead(io, value);
    std.debug.print("display_lead_ms set to {d} ms (saved to {s})\n", .{ value, display_lead_config_path });
}

/// Everything the display needs to know about the player, in a form it can
/// evaluate without touching the network.
///
/// This is the whole point of the split. A poll costs a round trip; polling
/// inline from the render loop would redraw every tick a round trip late. So
/// the polling thread publishes this, and the display loop reads it at the
/// moment it actually draws -- but it is exactly what the last poll reported,
/// with no interpolation between polls. The displayed play time only ever
/// changes when a fresh sample lands, and steps in whatever increments the
/// player itself reports in (usually, but not guaranteed to be, one second at
/// a time).
pub const Snapshot = struct {
    run_status: BlurayPlayerRunStatus = .Stopped,
    /// Last value the player actually reported, round-trip compensated (see
    /// `BlurayPlayer.getStatus`) but not yet including `display_lead_ms`.
    /// Milliseconds, not whole seconds, specifically so that compensation
    /// keeps its sub-second remainder all the way to `playTimeMillisLeadBy`
    /// instead of it being floored away before `display_lead_ms` is even
    /// applied.
    play_time_ms: i64 = 0,
    /// When the player last answered. Requests fail while it is busy -- trick
    /// play especially -- so a snapshot can be seconds old without anything
    /// looking wrong about it.
    sampled_ms: i64 = 0,

    /// Whether the play position is fresh enough to be trusted for anything
    /// that keys off *where* playback is.
    ///
    /// The position is always just whatever the last poll reported, frozen
    /// until the next one lands: fine to show on the clock even if a request
    /// or two has failed, but a position stale enough would pin a cue on
    /// screen long after playback actually left it behind.
    pub fn positionIsLive(self: Snapshot, now_ms: i64) bool {
        return self.run_status == .Playing and
            now_ms - self.sampled_ms <= stale_position_ms;
    }

    /// Play position in milliseconds, `display_lead_ms` included. No
    /// extrapolation from `now_ms` -- this is exactly the last poll's raw
    /// value, plus the lead; `now_ms` exists only for parity with
    /// `positionIsLive` and so callers don't need two different call shapes.
    pub fn playTimeMillis(self: Snapshot, now_ms: i64) i64 {
        return self.playTimeMillisLeadBy(now_ms, display_lead_ms.load(.acquire));
    }

    /// `playTimeMillis`, with the lead passed explicitly rather than read from
    /// `display_lead_ms`. Exists so the formula itself -- the part worth
    /// regression-testing -- can be exercised with concrete numbers regardless
    /// of whatever the live value is currently tuned to.
    fn playTimeMillisLeadBy(self: Snapshot, now_ms: i64, lead_ms: i64) i64 {
        _ = now_ms;
        return self.play_time_ms + lead_ms;
    }

    /// The whole second the player is showing.
    pub fn playTimeSeconds(self: Snapshot, now_ms: i64) u32 {
        const ms = self.playTimeMillis(now_ms);
        if (ms <= 0) return 0;
        return @intCast(@divFloor(ms, std.time.ms_per_s));
    }
};

/// Hands a freshly parsed cue file from the loader thread to the display loop.
///
/// The display loop must never touch the filesystem. Reading and parsing a cue
/// file means an SD-card read and a parse of the whole thing -- milliseconds,
/// unbounded, and landing at whatever moment the file happens to be saved. The
/// lookup itself is a scan of a sorted array and costs about a microsecond, so
/// it stays on the display loop; only the I/O moves.
const CueCell = struct {
    guard: std.atomic.Value(bool) = .init(false),
    /// Whether `pending` holds something the display loop has not taken yet.
    /// Checked with a plain atomic load so the common case never takes the lock.
    ready: std.atomic.Value(bool) = .init(false),
    pending: ?webvtt.CueList = null,

    fn acquire(self: *CueCell) void {
        while (self.guard.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn release(self: *CueCell) void {
        self.guard.store(false, .release);
    }

    /// Publish a newly loaded list, or null to mean "no cue file".
    fn publish(self: *CueCell, list: ?webvtt.CueList) void {
        self.acquire();
        defer self.release();
        // An earlier publication the display never collected is stale by
        // definition, and nothing holds a reference to it, so it can go here.
        if (self.pending) |stale| stale.deinit();
        self.pending = list;
        self.ready.store(true, .release);
    }

    /// Take whatever is waiting. The outer optional is "was there an update at
    /// all"; the inner one is the list, which is null when the selection was
    /// cleared and the line should go blank.
    fn take(self: *CueCell) ??webvtt.CueList {
        if (!self.ready.load(.acquire)) return null;
        self.acquire();
        defer self.release();
        const taken = self.pending;
        self.pending = null;
        self.ready.store(false, .release);
        return taken;
    }

    /// Release anything still held. Only safe once the loader has stopped.
    fn deinit(self: *CueCell) void {
        if (self.pending) |list| list.deinit();
        self.pending = null;
    }
};

/// Watch the selected cue file and parse it, off the display loop.
///
/// Also refreshes the timezone offset, for the same reason: working out the
/// local offset means opening and parsing `/etc/localtime`, which is file I/O
/// and has no business happening on a loop with frame deadlines to meet.
fn cueLoop(
    io: Io,
    allocator: std.mem.Allocator,
    cue_state: *cues.State,
    cell: *CueCell,
    zone: *time.SharedZone,
    stop: *std.atomic.Value(bool),
) void {
    var loaded_generation: u64 = 0;
    var name_buf: [cues.max_name_len]u8 = undefined;
    var name_len: usize = 0;
    var loaded_print: ?cues.Fingerprint = null;
    var next_zone_ms: i64 = 0;
    var next_stat_ms: i64 = 0;

    while (!stop.load(.acquire)) {
        const generation = cue_state.generation.load(.acquire);
        if (generation != loaded_generation) {
            loaded_generation = generation;
            loaded_print = null;
            next_stat_ms = 0; // load the new selection immediately
            name_len = 0;
            if (cue_state.currentName(&name_buf)) |name| {
                name_len = name.len;
                std.debug.print("cueLoop: selection -> '{s}' (directory: {s})\n", .{ name, cues.dirPath() });
            } else {
                // Selection cleared: blank the line rather than leaving the
                // previous file's cues running.
                std.debug.print("cueLoop: selection cleared\n", .{});
                cell.publish(null);
            }
        }

        const now_ms = time.nowMillis(io);

        if (name_len > 0 and now_ms >= next_stat_ms) {
            next_stat_ms = now_ms + CUE_STAT_INTERVAL_MS;
            const name = name_buf[0..name_len];
            // A file that cannot be stat'ed -- deleted, or a temporary being
            // renamed into place by an editor -- is left alone. The next pass
            // picks it up, and the cues already loaded beat a blank line.
            if (cues.fingerprint(io, name)) |current| {
                const stale = if (loaded_print) |previous| !previous.eql(current) else true;
                if (stale) {
                    if (cues.load(io, allocator, name)) |fresh| {
                        std.debug.print(
                            "cueLoop: loaded '{s}': {d} cues, title '{s}'\n",
                            .{ name, fresh.cues.len, fresh.title },
                        );
                        cell.publish(fresh);
                    } else |err| {
                        // Keep whatever is already on screen: a briefly broken
                        // file is normal while editing, and blanking line 2
                        // mid-movie over a typo is worse than stale cues.
                        std.debug.print("Failed to load cue file {s}: {}\n", .{ name, err });
                    }
                    // Recorded either way, so a file that fails to parse is not
                    // re-read every second until it is saved again.
                    loaded_print = current;
                }
            } else {
                // Silent before this fix: a directory-path mismatch, or a file
                // that simply is not there, produced no output at all -- the
                // exact "nothing happens, nothing loads, nothing logs" report
                // this is here to stop from recurring undiagnosed.
                std.debug.print(
                    "cueLoop: cannot stat '{s}' in {s} (missing, permissions, or directory mismatch)\n",
                    .{ name, cues.dirPath() },
                );
            }
        }

        if (now_ms >= next_zone_ms) {
            next_zone_ms = now_ms + time.SharedZone.refresh_interval_ms;
            zone.store(time.getTimezoneInfo(io));
        }

        io.sleep(.fromMilliseconds(CUE_THREAD_SLICE_MS), .awake) catch return;
    }
}

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
/// Dispatches the next request immediately after the previous one completes --
/// no artificial delay, no concurrency. A single in-flight request at a time
/// is deliberate: the player answers `cCMD_PST` in ~1000 ms while a disc
/// plays, which is by itself a tighter cadence than the display needs, and an
/// earlier version of this code that ran several requests concurrently found
/// the player's own small embedded web server appears to serialize them --
/// answering N concurrent requests in N times as long, not in parallel --
/// which only made every individual response slower for no throughput gained.
///
/// Runs until `stop` is set. Sleeps in short slices rather than straight
/// through so that shutdown is noticed promptly even while idle (e.g. no IP
/// configured).
fn pollLoop(
    io: Io,
    allocator: std.mem.Allocator,
    cell: *SnapshotCell,
    stop: *std.atomic.Value(bool),
) void {
    var player = BlurayPlayer.init(io, allocator);
    defer player.deinit();

    while (!stop.load(.acquire)) {
        const started_ms = time.nowMillis(io);
        player.poll();
        cell.publish(player.snapshot());

        // Dispatch the next request immediately -- see the doc comment above
        // for why. This sleep is not pacing the poll cadence; it only guards
        // against spinning the CPU when there is nothing to poll (no IP
        // configured, so `poll` returns instantly instead of after a round
        // trip), and it is the only place this loop checks `stop` in that
        // case, so it also bounds shutdown latency then.
        const elapsed_ms = time.nowMillis(io) - started_ms;
        if (elapsed_ms < POLL_THREAD_SLICE_MS) {
            io.sleep(.fromMilliseconds(POLL_THREAD_SLICE_MS - elapsed_ms), .awake) catch return;
        }
    }
}

pub const BlurayPlayerState = struct {
    /// Round-trip compensated, in milliseconds -- see `Snapshot.play_time_ms`.
    play_time_ms: i64,
    run_status: BlurayPlayerRunStatus,
    is_standby: bool,

    pub fn init() BlurayPlayerState {
        return BlurayPlayerState{
            .play_time_ms = 0,
            .run_status = .Stopped,
            .is_standby = true,
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
    /// When the player last actually answered, so a frozen position (stopped,
    /// paused, or simply not responding) can be told from a live one -- see
    /// `Snapshot.positionIsLive`.
    last_update_time: i64,
    http_client: std.http.Client,

    const Self = @This();
    /// Required by the DP-UB820-K; the CGI returns an error without it.
    const USER_AGENT = "MEI-LAN-REMOTE-CALL";
    /// Arbitrary client identifier sent when requesting a nonce.
    const AUTH_SID = "VORNE_M1000";
    /// Number of leading key characters echoed in `cAUTH_FORM`. Observed as 2
    /// on a UB-series player (`cAUTH_FORM=C4`); openHAB uses 3 for some keys,
    /// so this may need to become key-dependent if a key ever fails to work.
    const AUTH_FORM_LEN = 2;

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

    /// One HTTP round trip's worth of status, before it is folded into
    /// `self` by `poll`.
    const StatusSample = struct {
        sample_ms: i64,
        rtt_ms: i64,
        run_status: BlurayPlayerRunStatus,
        /// Compensated for the round trip already elapsed by the time this is
        /// in hand -- see `getStatus`. This is what feeds `state` and, from
        /// there, the display. Milliseconds, not whole seconds -- see
        /// `Snapshot.play_time_ms` for why the remainder matters.
        play_time_ms: i64,
        /// Exactly what the CGI returned, before compensation. Kept only for
        /// the log line, so the correction itself stays checkable against
        /// real hardware rather than being silently baked in.
        reported_play_time_seconds: u32,
        is_standby: bool,
    };

    /// Poll once and record exactly what came back -- no interpolation, no
    /// locking, no memory of previous samples beyond `state` /
    /// `last_update_time` themselves. What the display shows is this stored
    /// state plus `display_lead_ms` applied at render time; see `Snapshot`.
    pub fn poll(self: *Self) void {
        const sample = self.getStatus() catch |err| {
            std.debug.print("failed to get Blu-ray status: {}\n", .{err});
            return;
        };

        self.state.run_status = sample.run_status;
        self.state.play_time_ms = sample.play_time_ms;
        self.state.is_standby = sample.is_standby;
        self.last_update_time = sample.sample_ms;

        std.debug.print("poll: reported={d} position={d}ms status={s} rtt={d}ms\n", .{
            sample.reported_play_time_seconds, sample.play_time_ms, @tagName(sample.run_status), sample.rtt_ms,
        });
    }

    /// Current state in the form the display consumes.
    pub fn snapshot(self: *const Self) Snapshot {
        return .{
            .run_status = self.state.run_status,
            .play_time_ms = self.state.play_time_ms,
            .sampled_ms = self.last_update_time,
        };
    }

    /// The network round trip and response parsing. Touches none of `self`'s
    /// state -- `poll` folds the result in separately -- which is what keeps
    /// this function itself trivially testable-in-isolation-shaped, even
    /// though nothing currently calls it concurrently.
    fn getStatus(self: *Self) !StatusSample {
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
        const response = try self.sendHttpRequest(url, body_data);
        defer self.allocator.free(response);
        const recv_ms = time.nowMillis(self.io);
        // The player read its own clock somewhere inside the request window.
        // The midpoint is the least-biased estimate; timestamping on arrival
        // would bias every sample late by roughly a full round trip.
        const sample_ms = sent_ms + @divFloor(recv_ms - sent_ms, 2);
        const rtt_ms = recv_ms - sent_ms;

        const parsed = try self.parseResponse(response);
        defer self.allocator.free(parsed);

        if (parsed.len < 4) return error.UnexpectedResponse;

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

        if (play_time == std.math.maxInt(u32) - 1) { // -2 becomes maxInt-1 when parsed as u32
            return .{ .sample_ms = sample_ms, .rtt_ms = rtt_ms, .run_status = .Stopped, .play_time_ms = 0, .reported_play_time_seconds = 0, .is_standby = true };
        }

        // By the time this response is in hand, roughly `rtt_ms` of real time
        // has passed since the player read its own clock to answer -- while
        // playback is actually advancing, add that back in so the displayed
        // position reflects "now" rather than "whenever the player happened
        // to respond". A rough correction (this is a whole round trip, not
        // the midpoint) but a strictly one-sided bias, unlike jitter, so
        // leaving it uncorrected means the display is *always* behind, never
        // just occasionally imprecise. In milliseconds, not floored to whole
        // seconds: an earlier version added `rtt_ms / 1000` (integer
        // division) onto a whole-second value, which silently discarded
        // rtt_ms's sub-second remainder every single poll -- up to 999 ms of
        // real compensation, thrown away before `display_lead_ms` ever saw
        // it.
        const play_time_ms: i64 = @as(i64, play_time) * std.time.ms_per_s +
            (if (play_state == .Playing) rtt_ms else 0);

        return .{
            .sample_ms = sample_ms,
            .rtt_ms = rtt_ms,
            .run_status = play_state,
            .play_time_ms = play_time_ms,
            .reported_play_time_seconds = play_time,
            .is_standby = play_state == .Stopped,
        };
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

test "playTimeSeconds and playTimeMillis show exactly the last reported value" {
    // No interpolation: whatever wall-clock instant this is evaluated at, the
    // answer is the same until a fresh poll actually changes `play_time_ms`.
    const snap: Snapshot = .{
        .run_status = .Playing,
        .play_time_ms = 100_000,
        .sampled_ms = 50_000,
    };

    try std.testing.expectEqual(@as(u32, 100), snap.playTimeSeconds(50_000));
    try std.testing.expectEqual(@as(u32, 100), snap.playTimeSeconds(50_999));
    try std.testing.expectEqual(@as(u32, 100), snap.playTimeSeconds(57_400));
    try std.testing.expectEqual(@as(i64, 100_000), snap.playTimeMillis(50_400));
}

test "a sub-second remainder in play_time_ms survives to playTimeSeconds" {
    // Regression test: round-trip compensation used to be added as whole
    // seconds (`rtt_ms / 1000`, integer division) onto an already-whole-second
    // value, which silently discarded rtt_ms's remainder -- up to 999 ms of
    // real compensation, every single poll. `play_time_ms` is milliseconds
    // specifically so a remainder like this one survives to
    // `playTimeMillisLeadBy` instead of being floored away first.
    const snap: Snapshot = .{
        .run_status = .Playing,
        .play_time_ms = 100_700, // e.g. reported=100, rtt_ms=700
        .sampled_ms = 50_000,
    };
    try std.testing.expectEqual(@as(i64, 100_700), snap.playTimeMillis(50_000));
    try std.testing.expectEqual(@as(u32, 100), snap.playTimeSeconds(50_000));
    // A 400 ms lead pushes the 700 ms remainder over the next second
    // boundary -- exactly the kind of crossing a floored remainder could
    // never reach on its own.
    try std.testing.expectEqual(@as(i64, 101_100), snap.playTimeMillisLeadBy(50_000, 400));
}

test "a paused or stopped snapshot still shows the last reported second" {
    const paused: Snapshot = .{
        .run_status = .Paused,
        .play_time_ms = 1_234_000,
        .sampled_ms = 50_000,
    };
    try std.testing.expectEqual(@as(u32, 1234), paused.playTimeSeconds(50_000));
    try std.testing.expectEqual(@as(u32, 1234), paused.playTimeSeconds(999_000));
}

test "positionIsLive reflects freshness of the last poll, not lock state" {
    const fresh: Snapshot = .{
        .run_status = .Playing,
        .play_time_ms = 77_000,
        .sampled_ms = 50_000,
    };
    try std.testing.expect(fresh.positionIsLive(50_000));
    try std.testing.expect(fresh.positionIsLive(50_000 + stale_position_ms));
    try std.testing.expect(!fresh.positionIsLive(50_000 + stale_position_ms + 1));

    var paused = fresh;
    paused.run_status = .Paused;
    try std.testing.expect(!paused.positionIsLive(50_000));
}

test "parseDisplayLeadConfig accepts signed integers and rejects garbage" {
    try std.testing.expectEqual(@as(?i64, 900), parseDisplayLeadConfig("900"));
    try std.testing.expectEqual(@as(?i64, 900), parseDisplayLeadConfig("  900\n"));
    try std.testing.expectEqual(@as(?i64, -150), parseDisplayLeadConfig("-150\r\n"));
    try std.testing.expectEqual(@as(?i64, 0), parseDisplayLeadConfig("0"));
    try std.testing.expectEqual(@as(?i64, null), parseDisplayLeadConfig(""));
    try std.testing.expectEqual(@as(?i64, null), parseDisplayLeadConfig("   \n"));
    try std.testing.expectEqual(@as(?i64, null), parseDisplayLeadConfig("not a number"));
    try std.testing.expectEqual(@as(?i64, null), parseDisplayLeadConfig("900ms")); // trailing junk
}

test "configureDisplayLead leaves the value in place when the config file is absent" {
    var threaded: Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const before = display_lead_ms.load(.acquire);
    // No such file exists on any dev or CI machine, so this exercises exactly
    // the FileNotFound branch -- the common case before anyone has tuned it.
    configureDisplayLead(threaded.io());
    try std.testing.expectEqual(before, display_lead_ms.load(.acquire));
}

test "persistDisplayLeadTo writes a value that parses back correctly" {
    var threaded: Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = "bluray_display_lead_test_probe.txt";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    persistDisplayLeadTo(io, path, 250);

    const raw = try Io.Dir.readFileAlloc(.cwd(), io, path, std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(raw);
    try std.testing.expectEqual(@as(?i64, 250), parseDisplayLeadConfig(raw));
}

test "setDisplayLead applies to the running process immediately" {
    var threaded: Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    // Persistence (to display_lead_config_path) may fail here -- its directory
    // need not exist on every machine this runs on -- but the in-memory value
    // must still apply regardless: a persistence failure should not make a
    // live change from the web page look like it silently did nothing.
    setDisplayLead(threaded.io(), 250);
    try std.testing.expectEqual(@as(i64, 250), display_lead_ms.load(.acquire));
}

test "display_lead_ms shifts the displayed position, applied at the end and nowhere else" {
    const snap: Snapshot = .{
        .run_status = .Playing,
        .play_time_ms = 100_000,
        .sampled_ms = 50_000,
    };

    // With no lead, the raw reported value passes through unchanged.
    try std.testing.expectEqual(@as(i64, 100_000), snap.playTimeMillisLeadBy(60_000, 0));

    // A lead of 237 ms moves the output by exactly 237 ms and no more, and
    // does not depend on `now_ms` -- there is nothing else in the formula for
    // it to interact with.
    try std.testing.expectEqual(@as(i64, 100_237), snap.playTimeMillisLeadBy(60_000, 237));
    try std.testing.expectEqual(@as(i64, 100_237), snap.playTimeMillisLeadBy(999_999, 237));
}

test "playTimeMillis is wired to the live display_lead_ms" {
    // Proves the public entry point actually reaches the atomic, not just
    // that the LeadBy helper computes the right formula in isolation.
    const snap: Snapshot = .{
        .run_status = .Playing,
        .play_time_ms = 100_000,
        .sampled_ms = 50_000,
    };
    const lead = display_lead_ms.load(.acquire);
    try std.testing.expectEqual(snap.playTimeMillisLeadBy(60_000, lead), snap.playTimeMillis(60_000));
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
