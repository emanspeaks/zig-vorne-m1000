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
    resync_requested: *std.atomic.Value(bool),
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
    //     the phase lock deliberately schedules its polls either side of the
    //     player's tick edge -- exactly when this loop needs to be redrawing.
    //   * the cue file is watched and parsed on `cueLoop`, along with the
    //     timezone. Both are file I/O, and a cue file arrives whenever it
    //     happens to be saved.
    var cell: SnapshotCell = .{};
    var cue_cell: CueCell = .{};
    defer cue_cell.deinit();
    var zone: time.SharedZone = .init(time.getTimezoneInfo(io));

    var stop_workers = std.atomic.Value(bool).init(false);
    const poller = try std.Thread.spawn(.{}, pollLoop, .{ io, allocator, &cell, resync_requested, &stop_workers });
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
        // change: the next playback tick, the next real-time second, or the
        // next scroll step. Waking on a fixed grid instead would quantize each
        // of them to the grid period -- which for the two clocks is the
        // lateness this loop exists to avoid, and for the scroll is visible as
        // stutter, since evenly spaced steps are the whole of what makes a
        // character-cell marquee look smooth.
        var wake_ms = now_ms + DISPLAY_IDLE_SLICE_MS;
        if (snap.nextTickMs(now_ms)) |tick_ms| wake_ms = @min(wake_ms, tick_ms);
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

/// Fixed, hand-tunable forward offset folded into every extrapolated position
/// before it reaches the display or drives cue timing.
///
/// `phase_lock.PhaseLock.predict` is deliberately unbiased with respect to what
/// the player reports over the network -- it drives the lock's own
/// self-consistency checks against those raw reports, so biasing it there would
/// make the lock see permanent, spurious drift and fight itself. But there are
/// latencies downstream of the player's own report that no amount of
/// network-side correction can see: time spent in the player's own
/// decode/output pipeline, a TV or AVR's own processing delay, anything between
/// "the player's internal counter reached N" and a human seeing second N
/// appear on the screen. If the panel is observed to consistently read behind
/// what is actually playing even after `phase_lock`'s own accuracy is accounted
/// for, this is the knob: increase it in small steps (50-100 ms at a time)
/// while comparing the panel against the picture, until they line up. A
/// negative value pulls the display back instead.
///
/// No principled default exists -- it depends on hardware this code cannot
/// see -- so it starts at zero. Rule out a stall first, though: a resume that
/// stalls the display (see `phase_lock.PhaseLock.resumed`) produces exactly
/// the same symptom -- the panel reading a second or so behind -- as genuine
/// downstream hardware latency, but no lead value fixes a stall, since it is
/// not a constant offset. Re-check after confirming the clock keeps advancing
/// through a resume before tuning this.
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
    /// When the player last answered. Requests fail while it is busy -- trick
    /// play especially -- and the poller then backs off, so a snapshot can be
    /// seconds old without anything looking wrong about it.
    sampled_ms: i64 = 0,

    /// Whether the play position is being actively tracked, and so can be
    /// trusted for anything that keys off *where* playback is.
    ///
    /// Without an anchor the position is just whatever the last poll reported,
    /// frozen until the next one lands: fine to show on the clock, but it would
    /// pin a cue on screen long after playback left it behind.
    pub fn positionIsLive(self: Snapshot, now_ms: i64) bool {
        return self.run_status == .Playing and
            self.has_anchor and
            now_ms - self.sampled_ms <= stale_position_ms;
    }

    /// Play position in milliseconds at `now_ms`, `display_lead_ms` included.
    pub fn playTimeMillis(self: Snapshot, now_ms: i64) i64 {
        return self.playTimeMillisLeadBy(now_ms, display_lead_ms.load(.acquire));
    }

    /// `playTimeMillis`, with the lead passed explicitly rather than read from
    /// `display_lead_ms`. Exists so the formula itself -- the part worth
    /// regression-testing -- can be exercised with concrete numbers regardless
    /// of whatever the live value is currently tuned to.
    fn playTimeMillisLeadBy(self: Snapshot, now_ms: i64, lead_ms: i64) i64 {
        if (self.run_status != .Playing or !self.has_anchor) {
            return @as(i64, self.play_time_seconds) * std.time.ms_per_s;
        }
        return @as(i64, self.anchor_sec) * std.time.ms_per_s + (now_ms - self.anchor_ms) + lead_ms;
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
        return self.nextTickMsLeadBy(now_ms, display_lead_ms.load(.acquire));
    }

    /// `nextTickMs` with an explicit lead. See `playTimeMillisLeadBy`.
    ///
    /// Shifting the anchor `lead_ms` earlier before computing the edge is what
    /// keeps this in lockstep with `playTimeMillisLeadBy`: the wake schedule and
    /// the value it is waking up to show must never describe two different
    /// instants, in either direction, or a step could be woken for and then
    /// find nothing has actually changed yet (or the reverse: change without a
    /// wake to redraw it).
    fn nextTickMsLeadBy(self: Snapshot, now_ms: i64, lead_ms: i64) ?i64 {
        if (self.run_status != .Playing or !self.has_anchor) return null;
        const effective_anchor_ms = self.anchor_ms - lead_ms;
        return effective_anchor_ms + (@divFloor(now_ms - effective_anchor_ms, 1000) + 1) * 1000;
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
/// Runs until `stop` is set. Sleeps in short slices rather than straight
/// through to the next poll so that a mode change is noticed promptly.
fn pollLoop(
    io: Io,
    allocator: std.mem.Allocator,
    cell: *SnapshotCell,
    resync_requested: *std.atomic.Value(bool),
    stop: *std.atomic.Value(bool),
) void {
    var player = BlurayPlayer.init(io, allocator);
    defer player.deinit();

    while (!stop.load(.acquire)) {
        // A one-shot signal from the web page: `swap` both reads and clears it
        // atomically, so a request cannot be lost or double-fired between the
        // check and the reset.
        if (resync_requested.swap(false, .acq_rel)) {
            std.debug.print("pollLoop: forced PLL resync requested from the web page\n", .{});
            player.lock.forceResync(time.nowMillis(io));
        }

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

/// A snapshot of the fields of `phase_lock.PhaseLock` that anything watching
/// the log would plausibly want to know changed, taken before and after a
/// poll to report what actually happened.
///
/// Exists because `phase_lock.zig` is deliberately I/O-free -- see its module
/// doc -- so this observation, and the decision about what counts as
/// "something happened", lives here instead, in the layer that already does
/// I/O and is not exercised hundreds of times per test.
const LockObservable = struct {
    have_anchor: bool,
    locked: bool,
    refreshing: bool,
    anchor_ms: i64,
    anchor_sec: u32,
    anchor_err_ms: i64,

    fn capture(lock: *const phase_lock.PhaseLock) LockObservable {
        return .{
            .have_anchor = lock.have_anchor,
            .locked = lock.isLocked(),
            .refreshing = lock.refreshing,
            .anchor_ms = lock.anchor_ms,
            .anchor_sec = lock.anchor_sec,
            .anchor_err_ms = lock.anchor_err_ms,
        };
    }

    /// Log whatever changed between `before` (an earlier capture) and `self`
    /// (the current state), attributing it to the poll of kind `kind` that ran
    /// in between. Silent when nothing changed, which is most polls -- a
    /// straddle or mid-second check that simply agreed with the prediction.
    fn logChangesFrom(self: LockObservable, before: LockObservable, kind: PollKind) void {
        if (!before.have_anchor and self.have_anchor) {
            std.debug.print("phase_lock: anchor acquired -> sec={d} at ms={d} (+-{d}ms, kind={s})\n", .{ self.anchor_sec, self.anchor_ms, self.anchor_err_ms, @tagName(kind) });
        } else if (before.have_anchor and !self.have_anchor) {
            std.debug.print("phase_lock: anchor cleared (kind={s})\n", .{@tagName(kind)});
        } else if (self.have_anchor and (self.anchor_ms != before.anchor_ms or self.anchor_sec != before.anchor_sec)) {
            std.debug.print("phase_lock: anchor -> sec={d} at ms={d} (+-{d}ms, kind={s}, locked={})\n", .{ self.anchor_sec, self.anchor_ms, self.anchor_err_ms, @tagName(kind), self.locked });
        }

        if (!before.locked and self.locked) {
            std.debug.print("phase_lock: locked (+-{d}ms, kind={s})\n", .{ self.anchor_err_ms, @tagName(kind) });
        } else if (before.locked and !self.locked) {
            std.debug.print("phase_lock: lost lock, hunting (kind={s})\n", .{@tagName(kind)});
        }

        if (!before.refreshing and self.refreshing) {
            std.debug.print("phase_lock: periodic refresh started (kind={s})\n", .{@tagName(kind)});
        }

        // Bracket tightening: same anchor instant, but a narrower error bound.
        // Not itself a resync, so kept quieter than the events above -- useful
        // when specifically watching convergence, noisy otherwise.
        if (self.have_anchor and before.have_anchor and
            self.anchor_ms == before.anchor_ms and self.anchor_sec == before.anchor_sec and
            self.anchor_err_ms != before.anchor_err_ms)
        {
            std.debug.print("phase_lock: bracket tightened +-{d}ms -> +-{d}ms\n", .{ before.anchor_err_ms, self.anchor_err_ms });
        }
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
        // `phase_lock.zig` is deliberately free of I/O (its own module doc:
        // "so the state machine can be tested deterministically" -- a print
        // inside it would fire on every one of the hundreds of steps in a
        // single test). Comparing its externally-visible state before and after
        // instead gives the same visibility without that cost, from the layer
        // that already does I/O. Every field that a caller could plausibly ask
        // "did the lock just do something?" about is covered here, not only
        // the anchor value -- entering/leaving `locked`, starting a refresh,
        // and the bracket tightening (`anchor_err_ms` shrinking) are all real
        // events with nothing else to report them.
        const before = LockObservable.capture(&self.lock);

        self.getStatus(kind) catch |err| {
            std.debug.print("Failed to get Blu-ray status: {}\n", .{err});
            self.lock.retryAfterError(now);
            return;
        };
        self.lock.schedule(time.nowMillis(self.io), kind, self.state.run_status == .Playing);

        LockObservable.capture(&self.lock).logChangesFrom(before, kind);
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
            .sampled_ms = self.last_update_time,
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
        // When the player last actually answered, so consumers can tell a live
        // position from one frozen by a run of failed requests.
        self.last_update_time = sample_ms;

        if (run_status != .Playing) {
            // Nothing is ticking, and resuming will restart the tick at an
            // unrelated phase, so the lock is void.
            self.lock.sampleStopped();
            return;
        }

        // Playback just (re)started. The counter resumes at an unrelated phase
        // and often an unrelated position, but the display must not stall
        // waiting for a fresh bracket to form -- anchor immediately on this
        // first sample (`PhaseLock.resumed`) and let the hunt that follows
        // tighten it, rather than discarding the anchor outright and leaving
        // `predict` with nothing to show until a full cold hunt completes.
        if (!was_playing) self.lock.resumed(sample_ms, play_time);

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

test "display_lead_ms shifts the displayed position and its tick schedule together" {
    const snap: Snapshot = .{
        .run_status = .Playing,
        .has_anchor = true,
        .anchor_ms = 50_000,
        .anchor_sec = 100,
    };

    // With no lead, position and tick line up with the raw anchor.
    try std.testing.expectEqual(@as(i64, 110_000), snap.playTimeMillisLeadBy(60_000, 0));
    try std.testing.expectEqual(@as(i64, 51_000), snap.nextTickMsLeadBy(50_000, 0).?);

    // A lead of 237 ms must move both outputs by exactly 237 ms and no more:
    // the clock and its own wake schedule can never disagree about what "now"
    // means once a lead is applied, or a redraw would fire before -- or after
    // -- the value it exists to show has actually changed.
    try std.testing.expectEqual(@as(i64, 110_237), snap.playTimeMillisLeadBy(60_000, 237));
    try std.testing.expectEqual(@as(i64, 51_000 - 237), snap.nextTickMsLeadBy(50_000, 237).?);
}

test "playTimeMillis and nextTickMs are wired to the live display_lead_ms" {
    // Proves the public entry points actually reach the atomic, not just that
    // the LeadBy helpers compute the right formula in isolation.
    const snap: Snapshot = .{
        .run_status = .Playing,
        .has_anchor = true,
        .anchor_ms = 50_000,
        .anchor_sec = 100,
    };
    const lead = display_lead_ms.load(.acquire);
    try std.testing.expectEqual(snap.playTimeMillisLeadBy(60_000, lead), snap.playTimeMillis(60_000));
    try std.testing.expectEqual(snap.nextTickMsLeadBy(50_000, lead), snap.nextTickMs(50_000));
}

test "nextTickMs marks exactly when playTimeSeconds increments, whatever the lead" {
    // The invariant that actually matters, independent of DISPLAY_LEAD_MS's
    // current value: the wake schedule and the second it wakes up to show must
    // never come apart.
    const snap: Snapshot = .{
        .run_status = .Playing,
        .has_anchor = true,
        .anchor_ms = 50_000,
        .anchor_sec = 100,
    };
    const now: i64 = 60_000;
    const before = snap.playTimeSeconds(now);
    const tick = snap.nextTickMs(now).?;
    try std.testing.expectEqual(before, snap.playTimeSeconds(tick - 1));
    try std.testing.expectEqual(before + 1, snap.playTimeSeconds(tick));
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
