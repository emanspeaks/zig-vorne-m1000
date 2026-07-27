const std = @import("std");
const Io = std.Io;
const protocol = @import("protocol.zig");
const config = @import("config.zig");
const time = @import("time.zig");
const process_mgmt = @import("process_mgmt.zig");
const str_utils = @import("str_utils.zig");
const phase_lock = @import("phase_lock.zig");
const PollKind = phase_lock.PollKind;
const mode_mod = @import("mode.zig");
const Mode = mode_mod.Mode;
const cues = @import("cues.zig");
const webvtt = @import("webvtt.zig");
const vorne_charset = @import("vorne_charset.zig");
const dbg = @import("debug_log.zig");
const Marquee = @import("marquee.zig").Marquee;

const Writer = std.Io.Writer;
const maxbufsz = str_utils.maxbufsz;

pub const PLAYCHAR = protocol.DLE ++ "P"; // ►
pub const PAUSECHAR = "\xba"; // ║
pub const STOPCHAR = protocol.DLE ++ "G"; // ■
/// Below-space graphic character 0x0F (☼), reached the same way as the
/// other DLE-escaped glyphs on this panel: 0x40 + the code, so 0x4F = 'O'.
pub const SUNCHAR = protocol.DLE ++ "O"; // ☼

/// Prefixed to the play time while the phase lock has not converged, so the
/// panel reads `@0:00:00` rather than `0:00:00`.
///
/// Until the lock reaches `.locked` the displayed second is extrapolated from
/// an anchor whose phase is not yet trusted -- or, before there is an anchor at
/// all, from the raw last-polled value carried forward. Either can be up to a
/// second out. It is deliberately still shown and still advancing (stalling the
/// clock would be worse), but it should not read as authoritative while it is
/// being guessed at.
pub const LOCK_HUNTING_CHAR = "@";

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
/// file, network, *and* serial I/O is on other threads (the serial write and
/// its wait for the panel's reply live on `senderLoop`) -- which makes a
/// report here a genuine real-time-scheduling anomaly (OS jitter, a starved
/// thread) rather than, as it could be before the collator/sender split,
/// evidence of nothing more than the panel being slow to answer.
const DEADLINE_SLACK_MS: i64 = 12;

/// Ceiling on how long the display loop sleeps when it has nothing scheduled.
///
/// The two clocks on line 1 are woken for exactly: the loop sleeps until the
/// next real-time second or the next playback tick, whichever comes first. This
/// only bounds the latency of everything not modelled that way -- a scroll
/// step, a cue boundary, a mode change.
const DISPLAY_IDLE_SLICE_MS: i64 = 25;

/// How often both lines are redrawn in full even though nothing changed.
///
/// Two things make this necessary, and either alone would be enough.
///
/// Redraw suppression (see `last_line1`/`last_line2`) assumes a byte written to
/// the port is a byte the panel rendered. Nothing in this protocol guarantees
/// that: there is no flow control, and the unit's reply is drained without ever
/// being inspected, so a frame the panel misses is indistinguishable from one it
/// drew. Suppression then makes that permanent -- the content has not changed,
/// so it is never sent again, and the line stays stale until something unrelated
/// alters it.
///
/// Incremental column updates (`protocol.appendChangedColsToCmdList`) make it
/// sharper still: in the steady state *only the columns that moved* are ever
/// transmitted, so nothing repaints the rest of the line. Anything the panel
/// loses -- a dropped frame, arriving here from another display mode, a glitch
/// on the wire -- stays lost. Observed on hardware as a blank line with only
/// the seconds digits ticking, those being the only columns still being sent.
///
/// So this redraw covers *both* lines, in full, bypassing the diff. Scoping it
/// to line 2 alone (an earlier version did) is wrong: the reasoning that line 1
/// rewrites itself every second holds only while it is written whole.
const FORCE_REFRESH_MS: i64 = 3000;

/// How long after entering Blu-ray mode to keep forcing a full redraw on
/// every pass, rather than trusting `have_last1`/`have_last2` after the very
/// first one.
///
/// The first pass's full redraw is sent right behind the mode-entry init.
/// `protocol.send` waits for the panel's reply before either call returns,
/// which is a much stronger guarantee than a fixed delay -- but it is still
/// evidence the panel answered *something*, not proof the frame it just
/// received rendered correctly. If that one frame is lost anyway,
/// `have_last1`/`have_last2` are still marked true, since the write itself
/// succeeded, and every following pass reverts to an incremental diff against
/// a record of content the panel never actually showed -- so the panel can
/// stay blank for the full `FORCE_REFRESH_MS` before anything forces a
/// resend. Repeating the full redraw for a few seconds right after entry
/// means a lost frame self-heals on the very next
/// pass instead.
const ENTRY_FULL_REDRAW_MS: i64 = 3000;

/// Why line 2 currently holds whatever it holds. Logged only when it changes
/// (`runBlurayClocks`'s `seen_line2_source`), the same "log on change, not
/// every frame" discipline as the rest of this file's diagnostics -- this one
/// exists because "line 2 isn't updating" and "line 2 is correctly blank /
/// correctly showing the file name" turned out to look identical from the web
/// page and the panel alike, with no way to tell which branch actually ran.
const Line2Source = enum {
    /// Armed, live position, a cue covers it: showing that cue's text.
    cue,
    /// Armed, but the player is stopped -- see `Snapshot.positionIsLive`.
    armed_not_live,
    /// Armed and live, but `cueLoop` has not published a parsed file yet (or
    /// the selection was cleared).
    armed_no_cue_list,
    /// Armed and live, cues are loaded, but none covers the current position.
    armed_no_cue_here,
    /// Disarmed, a file is selected: showing its name.
    filename,
    /// Disarmed, nothing selected: the "Blu-Ray mode" fallback.
    nothing_selected,
};

/// Why a pass redraws both lines whole rather than diffing columns.
///
/// Named explicitly, rather than folded straight into a bool, so the reason
/// can be logged on change -- the same "log on change" discipline
/// `seen_line2_source` already uses below. Without this, "why did the panel
/// just repaint whole" was invisible in the log; only the fact that a frame
/// went out was.
const RedrawReason = enum {
    /// Nothing has ever been sent, or the last send's line wasn't recorded --
    /// there is no known-good record to diff against.
    missing_record,
    /// Still inside `ENTRY_FULL_REDRAW_MS` of entering the mode -- see its doc.
    entry_window,
    /// A cue's start or end marker was crossed this pass -- see `cue_boundary`.
    cue_boundary,
    /// `FORCE_REFRESH_MS` has elapsed since the last full redraw.
    periodic,
};

pub fn runBlurayClocks(
    io: Io,
    allocator: std.mem.Allocator,
    port: anytype,
    mode: *std.atomic.Value(Mode),
    cue_state: *cues.State,
    resync_requested: *std.atomic.Value(bool),
) !void {
    std.debug.print("Starting Blu-Ray run mode...\n", .{});

    var playtime_buf: [maxbufsz]u8 = undefined;
    // Holds the play time with `LOCK_HUNTING_CHAR` prefixed. Separate from
    // `playtime_buf` because the unmarked string is the source it is built
    // from, so they cannot share storage.
    var playtime_marked_buf: [maxbufsz]u8 = undefined;
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
    // For "log only on change" below -- see `Line2Source`.
    var seen_line2_source: ?Line2Source = null;
    // A cue's [start_ms, end_ms) span is unique within a well-formed file, so
    // it stands in for cue identity: `line2_source` alone stays `.cue` across
    // every cue in a file, which hid exactly the transition worth seeing when
    // a scroll looks like it got interrupted partway through.
    var seen_cue_span: ?struct { start_ms: i64, end_ms: i64 } = null;

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

    // What this loop wants shown, handed to `senderLoop` -- which owns the
    // port and decides how to actually get it onto the wire -- so that this
    // loop is never blocked by a serial round trip. See `DrawCell` and
    // `senderLoop`'s own doc for why the split exists.
    var draw_cell: DrawCell = .{};
    // A cue boundary is a one-shot event distinct from the published content
    // itself -- see `DrawCell`'s "latest wins" doc for why folding it into
    // the frame would risk the sender never seeing it.
    var cue_boundary_pending: std.atomic.Value(bool) = .init(false);

    var stop_workers = std.atomic.Value(bool).init(false);
    const poller = try std.Thread.spawn(.{}, pollLoop, .{ io, allocator, &cell, resync_requested, &stop_workers });
    const cue_thread = try std.Thread.spawn(.{}, cueLoop, .{ io, allocator, cue_state, &cue_cell, &zone, &stop_workers });
    const sender = try std.Thread.spawn(.{}, senderLoop, .{ io, allocator, port, &draw_cell, &cue_boundary_pending, &stop_workers });
    defer {
        stop_workers.store(true, .release);
        poller.join();
        cue_thread.join();
        sender.join();
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

        // A re-init was requested from the web page. Stop, and let
        // the dispatch loop in `main` service it: it owns the serial
        // port on this thread, and re-entering this function repaints
        // from scratch because the "what is on the panel" records
        // start empty. Checked without consuming -- `main` clears it.
        if (mode_mod.reinitPending()) {
            std.debug.print("Re-init requested, exiting bluray mode...\n", .{});
            return;
        }

        playtime_buf = undefined;
        clock_buf = undefined;
        try str_utils.clearVorneLineBuf(&linebuf);

        // One clock reading for the whole frame, so the cue-file check and the
        // scroll position cannot disagree about what "now" is.
        const now_ms = time.nowMillis(io);

        // Read the player's published state and evaluate it for *now*, rather
        // than using a value that was current whenever the last poll happened.
        const snap = cell.read();
        playtime = snap.playTimeSeconds(now_ms);
        const playtime_hms = time.timedeltaToHms(playtime);
        const playtime_hms_str = time.formatHms(playtime_hms, &playtime_buf) catch unreachable;
        // Mark the play time while the lock is still hunting -- see
        // `LOCK_HUNTING_CHAR`. This lengthens the string by one column, which
        // the clock's own budget below already accounts for by measuring
        // `playtime_str` rather than assuming a width.
        const playtime_str = if (snap.locked)
            playtime_hms_str
        else
            std.fmt.bufPrint(
                &playtime_marked_buf,
                LOCK_HUNTING_CHAR ++ "{s}",
                .{playtime_hms_str},
            ) catch unreachable;
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
        // The extra `-| 1` reserves the column right after the clock for
        // SUNCHAR below, the same way space for the play time is already
        // reserved -- otherwise an unrealistically long play time could
        // shrink the clock's own budget without leaving room for it.
        try str_utils.copyLeftJustify(&linebuf, clock_str, @min(clock_str.len, 20 -| playtime_str.len -| 1), null);
        try str_utils.copyLeftJustify(&linebuf, SUNCHAR, 1, clock_str.len);
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
                dbg.print(.cues, "bluray: display picked up {d} cues\n", .{list.cues.len});
            } else {
                dbg.print(.cues, "bluray: display cleared its cue list\n", .{});
            }
        }

        // The selected file's name, kept only to show while disarmed. Re-read
        // just when it changes, so the common pass takes no lock at all.
        const generation = cue_state.generation.load(.acquire);
        if (generation != seen_generation) {
            seen_generation = generation;
            name_len = 0;
            if (cue_state.currentName(&name_buf)) |name| name_len = name.len;
            dbg.print(.cues, "bluray: cue selection generation -> {d}, name='{s}'\n", .{
                generation, name_buf[0..name_len],
            });
        }

        // Line 2: the message due at the current play position, but only once
        // armed from the web page. Nothing about the player's status can tell
        // us the feature is running rather than a menu or a trailer, so the
        // decision is the operator's.
        try str_utils.clearVorneLineBuf(&line2buf);
        // A warning cue is pinned rather than swept: it has to be readable the
        // instant it appears, not a sweep later.
        var may_scroll = true;
        var line2_source: Line2Source = undefined;
        // Captured before the block below can change `seen_cue_span`, so it
        // can be compared against afterward -- see `cue_boundary`.
        const prev_cue_span = seen_cue_span;
        const line2: []const u8 = if (cue_state.isArmed()) blk: {
            // Only show a cue while the position it is keyed to is actually
            // being tracked. Stopped, paused, seeking, or simply not answering
            // all leave the position frozen at whatever the last poll returned,
            // and a frozen position pins whatever cue happened to cover it on
            // screen indefinitely -- which is exactly what happens when you
            // work the transport controls mid-message.
            if (!snap.positionIsLive()) {
                line2_source = .armed_not_live;
                seen_cue_span = null;
                break :blk "";
            }
            const list = cue_list orelse {
                line2_source = .armed_no_cue_list;
                seen_cue_span = null;
                break :blk "";
            };
            // Outside every cue's span the line is blank, checked afresh each
            // pass rather than left holding the last message.
            const cue = list.at(snap.playTimeMillis(now_ms)) orelse {
                line2_source = .armed_no_cue_here;
                seen_cue_span = null;
                break :blk "";
            };
            may_scroll = cue.scroll;
            line2_source = .cue;
            if (seen_cue_span == null or seen_cue_span.?.start_ms != cue.start_ms or seen_cue_span.?.end_ms != cue.end_ms) {
                seen_cue_span = .{ .start_ms = cue.start_ms, .end_ms = cue.end_ms };
                const cols = (str_utils.strlensz(cue.text) catch unreachable)[0];
                // `cue.text` is already transcoded into the panel's own
                // character set (see webvtt.zig's `appendPayload`), so
                // printing it directly is mojibake or an invisible control
                // byte on an ordinary terminal for anything outside plain
                // ASCII -- decode it back to readable UTF-8 for the log.
                var readable: std.ArrayList(u8) = .empty;
                defer readable.deinit(allocator);
                vorne_charset.decodeToUtf8(allocator, &readable, cue.text) catch {};
                dbg.print(.cues, 
                    "bluray: cue -> [{d}..{d}) scroll={} {d} bytes, {d} cols: \"{s}\"\n",
                    .{ cue.start_ms, cue.end_ms, cue.scroll, cue.text.len, cols, readable.items },
                );
            }
            break :blk cue.text;
        } else if (name_len > 0) blk: {
            // Disarmed: show which file is loaded, so it is obvious the right
            // one was picked before starting the disc. Also clears the seen
            // cue span, so re-arming into the very same cue (stop/start
            // around the same position) logs it again instead of staying
            // silent because the span "hasn't changed" since before the
            // disarm.
            line2_source = .filename;
            seen_cue_span = null;
            break :blk cues.baseName(name_buf[0..name_len]);
        } else blk: {
            line2_source = .nothing_selected;
            seen_cue_span = null;
            break :blk "Blu-Ray mode";
        };

        // Whether a cue's start or end marker was crossed this pass -- not
        // whether line 2's *content* changed, which a marquee step also does,
        // every ~400 ms, and which does not warrant this. Entering a cue's
        // span, leaving one (to blank or to a different cue), and a disarm/
        // rearm that resets `seen_cue_span` to null are exactly the
        // transitions `seen_cue_span` already exists to detect (see its own
        // doc), so this only needs to notice when this pass changed it.
        const cue_boundary = !std.meta.eql(prev_cue_span, seen_cue_span);

        if (seen_line2_source == null or line2_source != seen_line2_source.?) {
            seen_line2_source = line2_source;
            dbg.print(.display, 
                "bluray: line2 source -> {s} (armed={}, live={}, name='{s}', has_cue_list={})\n",
                .{ @tagName(line2_source), cue_state.isArmed(), snap.positionIsLive(), name_buf[0..name_len], cue_list != null },
            );
        }

        const line2_window = if (may_scroll)
            scroller.window(line2, str_utils.maxchars, now_ms)
        else blk: {
            // Nothing this marquee produced is on screen, so drop its sweep
            // state -- otherwise returning to a message it scrolled before
            // resumes it mid-sweep instead of restarting. See `Marquee.reset`.
            scroller.reset();
            // Truncate by *column*, not by byte. A DLE-escaped glyph is two
            // bytes for one column, so a byte cut can land between the DLE
            // and the code byte it escapes and leave a dangling DLE at the
            // end of the text. The panel then takes the next byte on the wire
            // as the escaped code -- and that byte is the CR terminating the
            // SPP frame. The frame is left malformed, its CRC fails, and the
            // panel discards the whole thing, line 1 included: the write
            // reports success and nothing renders at all.
            const cols = (str_utils.strlensz(line2) catch unreachable)[0];
            if (cols <= str_utils.maxchars) break :blk line2;
            break :blk line2[0..(str_utils.idxChar2Str(line2, str_utils.maxchars) catch line2.len)];
        };

        // `copyLeftJustify`'s limit is a column count, so it needs the
        // window's width in columns -- `line2_window.len` is its width in
        // bytes, which is larger for any text holding a DLE pair.
        const line2_cols = (str_utils.strlensz(line2_window) catch unreachable)[0];
        try str_utils.copyLeftJustify(&line2buf, line2_window, @min(line2_cols, str_utils.maxchars), null);

        // Hand the freshly built frame to `senderLoop`, which owns the port
        // and decides how -- or whether -- to get it onto the wire (one frame
        // per send, line 1 preferred over line 2, full redraw vs. column diff;
        // see that function's own doc). Publishing is a spin-locked copy of
        // two small buffers, never a write to the panel, so this loop is never
        // blocked by a serial round trip -- which is the whole point of the
        // split: this loop can always tell the sender what *should* be shown
        // right now, even while the sender is still busy getting the last
        // thing it was told out the door.
        draw_cell.publish(&linebuf, &line2buf);
        // A one-shot flag, not folded into the published frame: `draw_cell`
        // is "latest wins" (see its own doc), so a boundary flagged on one
        // publish could be silently superseded by a later one before the
        // sender ever looks. `cue_boundary` only means "this pass changed
        // `seen_cue_span`" -- whatever content the sender eventually reads
        // already reflects the post-boundary state regardless of which
        // publish it came from, so it does not matter that the flag and the
        // frame that originally set it may not arrive together.
        if (cue_boundary) cue_boundary_pending.store(true, .release);

        // Sleep until the next moment something on the display is due to
        // change: the next playback tick, the next real-time second, or the
        // next scroll step. Waking on a fixed grid instead would quantize each
        // of them to the grid period -- which for the two clocks is the
        // lateness this loop exists to avoid, and for the scroll is visible as
        // stutter, since evenly spaced steps are the whole of what makes a
        // character-cell marquee look smooth.
        //
        // Scheduled from `now_ms`, the single clock reading this whole pass
        // already agreed on. That is only safe because this loop no longer
        // performs the one operation that used to make it stale by the time
        // scheduling ran: the blocking write-and-wait-for-reply now lives on
        // `senderLoop`, on its own thread, so nothing between capturing
        // `now_ms` above and reading it again here can take a meaningfully
        // different amount of time pass to pass. Before the split, this
        // reused the frame's `now_ms` even though a serial round trip could
        // land in between, which was the dominant source of the "Display pass
        // N ms late" reports -- see the split's own rationale on `senderLoop`.
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
            if (snap.positionIsLive()) {
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
            dbg.print(.display, 
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
    /// Whether the lock's phase estimate is tight enough to trust, as opposed
    /// to merely having an anchor to extrapolate from. Deliberately distinct
    /// from `has_anchor`: the display keeps running off a free-wheeling anchor
    /// while the estimate re-tightens, and this is what says so on the panel
    /// (see `LOCK_HUNTING_CHAR`) rather than silently showing a time that may
    /// be up to a second out.
    locked: bool = false,
    /// When the player last answered. Requests fail while it is busy -- trick
    /// play especially -- and the poller then backs off, so a snapshot can be
    /// seconds old without anything looking wrong about it.
    sampled_ms: i64 = 0,

    /// Whether the play position means anything for keying cue lookups and
    /// boundary waits off it.
    ///
    /// Only a stopped player is excluded, and deliberately nothing else.
    ///
    /// It does not require `has_anchor`: `playTimeMillis` already falls back
    /// to the raw last-polled value when there is no anchor, so gating on the
    /// anchor bought nothing but *silence* -- while the lock re-acquires
    /// (after a seek, a resume, or simply a fresh start) this blanked cues, or
    /// pinned a stale one from before arming, even though the underlying
    /// position was perfectly usable throughout.
    ///
    /// It does not require the snapshot to be *fresh* either, which is the
    /// less obvious half. A staleness gate here reads as an obviously good
    /// idea -- don't show a message once playback has moved on -- but the
    /// round trip to this player is around a second, so `sampled_ms` is
    /// already several hundred ms old the instant it is recorded, and the
    /// poller staggers its cadence and backs off after an error. Any stretch
    /// where a poll slips past the threshold blanks line 2 outright, and the
    /// symptom is cues that vanish and reappear for no reason visible
    /// anywhere in the log. A position that is a second or two old is a far
    /// better cue key than no position at all, so the gate cost much more
    /// than it bought.
    ///
    /// `.Paused` counts, not just `.Playing`: `playTimeMillisLeadBy` returns
    /// the frozen last-polled value whenever `run_status != .Playing`, so a
    /// paused position never extrapolates forward, it just stays put -- and a
    /// frozen-but-known position is exactly as valid a lookup key as a moving
    /// one. Blanking on pause also interrupts a message at the moment someone
    /// paused to read it, and a scrolling cue should keep sweeping through a
    /// pause, since the sweep runs on wall-clock time, not play position.
    pub fn positionIsLive(self: Snapshot) bool {
        return self.run_status != .Stopped;
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
        // Not playing: the counter is not moving, so the last reported value
        // *is* the position. Freezing here is correct.
        if (self.run_status != .Playing) {
            return @as(i64, self.play_time_seconds) * std.time.ms_per_s;
        }
        // Playing but hunting: extrapolate from the sample rather than sitting
        // on it. Freezing here was wrong -- the player is still counting, so
        // the position only lurched forward when a poll landed, roughly once a
        // second, and sat stale in between. Cues keyed off it fired a beat
        // late and in visible steps until the lock acquired, which reads as
        // line 2 lagging the picture "until the PLL stops hunting".
        //
        // The counter reached `play_time_seconds` somewhere in
        // `(sampled_ms - 1s, sampled_ms]`, so its midpoint is `sampled_ms -
        // 500` -- the same convention `phase_lock.rebase` uses when it seeds
        // an anchor from a single sample. Using it here too means the estimate
        // does not visibly jump at the moment the lock acquires.
        if (!self.has_anchor) {
            return @as(i64, self.play_time_seconds) * std.time.ms_per_s +
                (now_ms - (self.sampled_ms - 500)) + lead_ms;
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
        if (self.run_status != .Playing) return null;
        // While hunting, the same pseudo-anchor `playTimeMillisLeadBy` uses.
        // It has to be the same one: this schedules the wake, that computes
        // the value being woken up to show, and if they disagree the loop
        // either wakes to find nothing changed or changes with no wake to
        // redraw it. Returning null here (as this did) meant no tick wake at
        // all while hunting, leaving line 1's play time to be picked up
        // whenever the idle slice next came round -- up to
        // `DISPLAY_IDLE_SLICE_MS` late, and unevenly, which is the same
        // erratic advance in a different guise.
        const anchor_ms = if (self.has_anchor) self.anchor_ms else self.sampled_ms - 500;
        const effective_anchor_ms = anchor_ms - lead_ms;
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
                dbg.print(.cues, "cueLoop: selection -> '{s}' (directory: {s})\n", .{ name, cues.dirPath() });
            } else {
                // Selection cleared: blank the line rather than leaving the
                // previous file's cues running.
                dbg.print(.cues, "cueLoop: selection cleared\n", .{});
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
                        dbg.print(.cues, 
                            "cueLoop: loaded '{s}': {d} cues, title '{s}'\n",
                            .{ name, fresh.cues.len, fresh.title },
                        );
                        cell.publish(fresh);
                    } else |err| {
                        // Keep whatever is already on screen: a briefly broken
                        // file is normal while editing, and blanking line 2
                        // mid-movie over a typo is worse than stale cues.
                        dbg.print(.cues, "Failed to load cue file {s}: {}\n", .{ name, err });
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
                dbg.print(.cues, 
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

/// Hands the collator's (`runBlurayClocks`) freshly built frame to
/// `senderLoop`. A spin lock, for the same reason as `SnapshotCell`: the
/// critical section is a copy of two small fixed buffers, and
/// `std.Thread.Mutex` does not exist in 0.16.
///
/// Deliberately "latest wins," not a queue: the sender only ever cares what
/// should be on screen *right now*. A publish the sender has not yet picked
/// up is simply overwritten by the next one rather than queued behind it --
/// nothing is lost by that, since an intermediate scroll-step frame the
/// sender never saw was already superseded by the one it does see.
const DrawCell = struct {
    guard: std.atomic.Value(bool) = .init(false),
    /// Whether the collator has published anything yet -- `senderLoop` has
    /// nothing to send before the first pass runs.
    have: bool = false,
    line1: [maxbufsz]u8 = undefined,
    line2: [maxbufsz]u8 = undefined,

    const Frame = struct { line1: [maxbufsz]u8, line2: [maxbufsz]u8 };

    fn acquire(self: *DrawCell) void {
        while (self.guard.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn release(self: *DrawCell) void {
        self.guard.store(false, .release);
    }

    fn publish(self: *DrawCell, line1: *const [maxbufsz]u8, line2: *const [maxbufsz]u8) void {
        self.acquire();
        defer self.release();
        self.line1 = line1.*;
        self.line2 = line2.*;
        self.have = true;
    }

    /// The most recently published frame, or null before the collator has
    /// published anything at all.
    fn read(self: *DrawCell) ?Frame {
        self.acquire();
        defer self.release();
        if (!self.have) return null;
        return .{ .line1 = self.line1, .line2 = self.line2 };
    }
};

/// How often `senderLoop` checks `DrawCell` for fresh content when it has
/// nothing outstanding. Not a pacing mechanism -- `protocol.send` already
/// paces the wire by waiting for the panel's reply -- just how quickly a
/// freshly published frame is noticed while the sender is idle. Small enough
/// that a tick or scroll step is picked up as soon as whatever send was
/// already in flight completes; the panel's own round trip, not this, is what
/// actually bounds latency.
const SENDER_IDLE_SLICE_MS: i64 = 10;

/// Owns the serial port and turns whatever the collator (`runBlurayClocks`)
/// last published into frames on the wire.
///
/// Split out from the collator so the two are never coupled by a blocking
/// call. Before this split, one thread did both jobs: build the draw buffers,
/// diff them, and send -- all in the same pass. The diffing itself was always
/// correct and immediate (a fresh `now_ms` and a `memcmp`, every pass), but it
/// could not *run* while that same thread was blocked inside `protocol.send`
/// waiting for the panel's reply. A line-2 scroll-step send starting shortly
/// before a real-time tick came due would still be in flight when it did, so
/// the tick was not even looked at until the pass after -- by which point a
/// second real second had often already ticked over. That produced the clock
/// visibly skipping a second while the marquee was scrolling. A round-trip
/// estimate was tried first, predicting whether a line-2 send would still be
/// outstanding by the next tick and skipping it if so -- a real improvement,
/// but only probabilistic: it depended on the estimate being right.
///
/// This is the structural fix instead: the collator never touches the port,
/// so it is never blocked and always holds the true current state; this
/// thread continuously sends whatever `draw.read()` says is *latest*, gated
/// only by however long the panel actually takes to answer. Because it always
/// re-reads fresh after every send completes, a tick that landed mid-send is
/// simply reflected the moment it checks again -- no prediction needed.
///
/// Owns every piece of "what has the panel actually been sent" bookkeeping --
/// `last_line1`/`last_line2`/`have_last1`/`have_last2`, the redraw-reason
/// timers (`FORCE_REFRESH_MS`, `ENTRY_FULL_REDRAW_MS`) -- since it is the only
/// thread that knows what actually went out. The collator does not, and must
/// not: it only knows what *should* be shown.
///
/// One frame per send, and line 1 preferred over line 2 when both are due --
/// unchanged from the single-thread version, and for the same reason: nothing
/// renders until a frame's CRC arrives, so a frame carrying both lines costs
/// roughly 31 ms against 18 ms for one alone, and two frames back to back with
/// no gap is what makes the panel drop the second one (no flow control, small
/// input buffer). Deferring line 2 to the next send costs it at most one
/// `SENDER_IDLE_SLICE_MS` of latency and cannot starve, since line 1 changes
/// only a couple of times a second.
fn senderLoop(
    io: Io,
    allocator: std.mem.Allocator,
    port: anytype,
    draw: *DrawCell,
    cue_boundary_pending: *std.atomic.Value(bool),
    stop: *std.atomic.Value(bool),
) void {
    var cmd_parts = std.ArrayList(u8).empty;
    defer cmd_parts.deinit(allocator);

    // Last content actually put on the wire, so only a line that changed is
    // re-clocked out -- see the equivalent comment this replaced in
    // `runBlurayClocks` for the full rationale. A flag per line: the two are
    // sent in separate passes, so a single shared flag would mark one line's
    // record valid on the strength of the *other* line having gone out.
    var last_line1: [maxbufsz]u8 = undefined;
    var last_line2: [maxbufsz]u8 = undefined;
    var have_last1 = false;
    var have_last2 = false;
    // See `FORCE_REFRESH_MS`.
    var last_refresh_ms: i64 = 0;
    // See `ENTRY_FULL_REDRAW_MS`. This thread's own start is mode entry, so
    // there is no need for the lazy "set from the first pass" `?i64` the
    // collator used to need before it had a `now_ms` to seed from.
    const entry_ms = time.nowMillis(io);
    // For "log only on change" -- see `RedrawReason`.
    var seen_redraw_reason: ?RedrawReason = null;

    while (!stop.load(.acquire)) {
        const frame = draw.read() orelse {
            io.sleep(.fromMilliseconds(SENDER_IDLE_SLICE_MS), .awake) catch return;
            continue;
        };
        const linebuf = frame.line1;
        const line2buf = frame.line2;

        const now_ms = time.nowMillis(io);
        // One-shot: `swap` both reads and clears it, so a boundary flagged
        // between this check and the last cannot be lost or double-counted.
        const cue_boundary = cue_boundary_pending.swap(false, .acq_rel);

        cmd_parts.clearRetainingCapacity();
        const line1_changed = !have_last1 or !std.mem.eql(u8, &linebuf, &last_line1);
        // Whether the *content* changed, kept separate from whether it gets
        // sent: a periodic refresh re-sends identical content, and reporting
        // that as a line-2 update every few seconds would bury the
        // transitions actually worth reading in the log.
        const line2_changed = !have_last2 or !std.mem.eql(u8, &line2buf, &last_line2);

        // A full redraw of *both* lines, periodically and whenever what is on
        // the panel is unknown -- entering Blu-ray mode, or after a failed
        // send. Not optional once line updates are incremental: a column diff
        // rewrites only the columns that moved, so nothing in the steady
        // state ever repaints the rest of a line the panel lost to a dropped
        // frame or a glitch on the wire.
        const in_entry_window = now_ms - entry_ms < ENTRY_FULL_REDRAW_MS;

        const redraw_reason: ?RedrawReason = if (!have_last1 or !have_last2)
            .missing_record
        else if (in_entry_window)
            .entry_window
        else if (cue_boundary)
            .cue_boundary
        else if (now_ms - last_refresh_ms >= FORCE_REFRESH_MS)
            .periodic
        else
            null;
        const full_redraw = redraw_reason != null;

        if (redraw_reason != seen_redraw_reason) {
            seen_redraw_reason = redraw_reason;
            if (redraw_reason) |reason| {
                dbg.print(.redraw, "bluray: full redraw -> {s}\n", .{@tagName(reason)});
            }
        }

        // Which lines this send actually carried, so the records are updated
        // for exactly those and no others.
        var sent_line1 = false;
        var sent_line2 = false;

        // An allocator failure building the command string (a handful of
        // bytes) is exceedingly unlikely, but is skipped rather than crashing
        // this thread: `continue` re-reads `draw` next iteration, so a
        // transient hiccup just costs one send's worth of latency, same as
        // any other skipped pass.
        if (full_redraw) {
            last_refresh_ms = now_ms;
            protocol.appendStrToCmdList(allocator, &cmd_parts, 1, 1, &linebuf) catch |err| {
                std.debug.print("bluray: failed to build display frame: {}\n", .{err});
                continue;
            };
            protocol.appendStrToCmdList(allocator, &cmd_parts, 2, 1, &line2buf) catch |err| {
                std.debug.print("bluray: failed to build display frame: {}\n", .{err});
                continue;
            };
            sent_line1 = true;
            sent_line2 = true;
        } else if (line1_changed) {
            // Send only the columns that moved -- see `appendChangedColsToCmdList`.
            protocol.appendChangedColsToCmdList(allocator, &cmd_parts, 1, &last_line1, &linebuf) catch |err| {
                std.debug.print("bluray: failed to build display frame: {}\n", .{err});
                continue;
            };
            sent_line1 = true;
        } else if (line2_changed) {
            // Line 2 yields to line 1 -- see this function's own doc.
            protocol.appendChangedColsToCmdList(allocator, &cmd_parts, 2, &last_line2, &line2buf) catch |err| {
                std.debug.print("bluray: failed to build display frame: {}\n", .{err});
                continue;
            };
            sent_line2 = true;
        }

        if (cmd_parts.items.len > 0) {
            // Logged on every attempt, not just failures -- this is the one
            // point that can confirm or rule out the send path itself when the
            // panel and the `cue -> ...`/`line2 source -> ...` logs disagree
            // about what should be on screen.
            const report_line2 = sent_line2 and line2_changed and dbg.enabled(.serial);
            var readable: std.ArrayList(u8) = .empty;
            defer readable.deinit(allocator);
            if (report_line2) vorne_charset.decodeToUtf8(allocator, &readable, &line2buf) catch {};

            if (protocol.sendUnitDisplayCmd(allocator, port, 1, cmd_parts.items)) |_| {
                if (sent_line1) {
                    last_line1 = linebuf;
                    have_last1 = true;
                }
                if (sent_line2) {
                    last_line2 = line2buf;
                    have_last2 = true;
                }
                if (report_line2) {
                    dbg.print(.serial, "bluray: sending line 2: \"{s}\" send status: success\n", .{readable.items});
                }
            } else |err| {
                // Unconditional: a frame that did not reach the panel is an
                // operational fault, not diagnostic chatter, and suppressing
                // it because `serial` happens to be switched off would hide
                // the single most useful line in the log.
                std.debug.print("bluray: failed to send display frame: {}\n", .{err});
            }
        } else {
            // Nothing changed, so nothing to send -- wait a slice before
            // checking `draw` again rather than busy-looping. When something
            // *was* sent, loop straight back around instead: `protocol.send`
            // already paced the wire by waiting for the reply, and checking
            // immediately is what lets a tick that landed mid-send be picked
            // up the instant this thread is free, rather than up to another
            // `SENDER_IDLE_SLICE_MS` late.
            io.sleep(.fromMilliseconds(SENDER_IDLE_SLICE_MS), .awake) catch return;
        }
    }
}

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
            dbg.print(.pll, "pollLoop: forced PLL resync requested from the web page\n", .{});
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
    anchor_ms: i64,
    anchor_sec: u32,
    anchor_err_ms: i64,

    fn capture(lock: *const phase_lock.PhaseLock) LockObservable {
        return .{
            .have_anchor = lock.have_anchor,
            .locked = lock.isLocked(),
            .anchor_ms = lock.anchor_ms,
            .anchor_sec = lock.anchor_sec,
            .anchor_err_ms = lock.anchor_err_ms,
        };
    }

    /// `PhaseLock.predict`, computed from this captured state. Mirrors that
    /// function exactly, so the drift printed per poll is the drift the lock
    /// itself was facing when it evaluated the sample -- computed against the
    /// anchor as it stood *before* the sample was folded in, since afterwards
    /// a rebase would have already erased the disagreement being measured.
    /// Meaningful only when `have_anchor`; callers check.
    fn predictAt(self: LockObservable, at_ms: i64) u32 {
        const elapsed_ms = at_ms - self.anchor_ms;
        if (elapsed_ms < 0) return self.anchor_sec;
        return self.anchor_sec +| @as(u32, @intCast(@divFloor(elapsed_ms, 1000)));
    }

    /// Log whatever changed between `before` (an earlier capture) and `self`
    /// (the current state), attributing it to the poll of kind `kind` that ran
    /// in between. Silent when nothing changed, which is most polls -- a
    /// sample that simply agreed with the accumulated estimate.
    fn logChangesFrom(self: LockObservable, before: LockObservable, kind: PollKind) void {
        if (!before.have_anchor and self.have_anchor) {
            dbg.print(.pll, "phase_lock: anchor acquired -> sec={d} at ms={d} (+-{d}ms, kind={s})\n", .{ self.anchor_sec, self.anchor_ms, self.anchor_err_ms, @tagName(kind) });
        } else if (before.have_anchor and !self.have_anchor) {
            dbg.print(.pll, "phase_lock: anchor cleared (kind={s})\n", .{@tagName(kind)});
        } else if (self.have_anchor and (self.anchor_ms != before.anchor_ms or self.anchor_sec != before.anchor_sec)) {
            dbg.print(.pll, "phase_lock: anchor -> sec={d} at ms={d} (+-{d}ms, kind={s}, locked={})\n", .{ self.anchor_sec, self.anchor_ms, self.anchor_err_ms, @tagName(kind), self.locked });
        }

        if (!before.locked and self.locked) {
            dbg.print(.pll, "phase_lock: locked (+-{d}ms, kind={s})\n", .{ self.anchor_err_ms, @tagName(kind) });
        } else if (before.locked and !self.locked) {
            dbg.print(.pll, "phase_lock: lost lock, re-acquiring (kind={s})\n", .{@tagName(kind)});
        }

        // Interval tightening: same anchor, narrower error bound. Not itself
        // a resync, so kept quieter than the events above -- useful when
        // specifically watching convergence, noisy otherwise.
        if (self.have_anchor and before.have_anchor and
            self.anchor_ms == before.anchor_ms and self.anchor_sec == before.anchor_sec and
            self.anchor_err_ms != before.anchor_err_ms)
        {
            dbg.print(.pll, "phase_lock: estimate tightened +-{d}ms -> +-{d}ms\n", .{ before.anchor_err_ms, self.anchor_err_ms });
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
    /// Round trip of the most recent successful request, for telemetry.
    last_rtt_ms: i64,
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
            .last_rtt_ms = 0,
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
        // that already does I/O.
        const before = LockObservable.capture(&self.lock);
        const prev_sample_ms = self.last_update_time;

        self.getStatus(kind) catch |err| {
            dbg.print(.bluray, "Failed to get Blu-ray status: {}\n", .{err});
            self.lock.retryAfterError(now);
            return;
        };
        self.lock.schedule(time.nowMillis(self.io), kind, self.state.run_status == .Playing);

        // Everything below is reporting only, and its placement is what keeps
        // it from affecting the sync itself:
        //   * the sample window (the sent/recv timestamps inside `getStatus`)
        //     closed before any printing, so a slow console cannot skew a
        //     sample instant;
        //   * `next_poll_ms` is an absolute deadline chosen above, so time
        //     spent printing comes out of this thread's subsequent sleep, not
        //     out of the poll cadence;
        //   * this is the polling thread -- the render loop never executes any
        //     of it.
        const after = LockObservable.capture(&self.lock);
        after.logChangesFrom(before, kind);

        if (self.last_update_time == prev_sample_ms) {
            // The request went out but no sample landed: player off, CGI
            // error, or an unparseable response. Previously silent, which made
            // "the PLL is not updating" indistinguishable from "everything
            // agrees" in the log.
            dbg.print(.pll, "pll: {s} no sample (player off or CGI error)\n", .{@tagName(kind)});
            return;
        }

        const sample_ms = self.last_update_time;
        const reported = self.state.play_time_seconds;
        if (self.state.run_status != .Playing) {
            dbg.print(.pll, "pll: {s} reported={d} status={s} rtt={d}ms\n", .{
                @tagName(kind), reported, @tagName(self.state.run_status), self.last_rtt_ms,
            });
        } else if (before.have_anchor) {
            // The line that matters when chasing drift: the value the player
            // reported vs. what the pre-sample anchor predicted for that same
            // instant. drift=0 means the model and the player agree exactly;
            // a persistent nonzero drift with `into` well away from 0/1000 is
            // a genuine value error on our side; drift of +-1 with `into` near
            // an edge is rounding ambiguity, not error.
            const predicted = before.predictAt(sample_ms);
            const drift = @as(i64, reported) - @as(i64, predicted);
            const into_ms = @mod(sample_ms - before.anchor_ms, 1000);
            dbg.print(.pll, "pll: {s} reported={d} predicted={d} drift={d} into={d}ms anchor=+-{d}ms rtt={d}ms {s}\n", .{
                @tagName(kind),   reported,                                  predicted,
                drift,            into_ms,                                   after.anchor_err_ms,
                self.last_rtt_ms, if (after.locked) "locked" else "hunting",
            });
        } else {
            dbg.print(.pll, "pll: {s} reported={d} (no anchor yet) rtt={d}ms\n", .{
                @tagName(kind), reported, self.last_rtt_ms,
            });
        }
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
            .locked = self.lock.isLocked(),
            .sampled_ms = self.last_update_time,
            .anchor_ms = self.lock.anchor_ms,
            .anchor_sec = self.lock.anchor_sec,
        };
    }

    /// Fold one status sample into the phase lock.
    ///
    /// `sample_ms` is the best estimate of when the player read its own
    /// clock, and is what `last_update_time` (freshness tracking) uses.
    /// `lock_sample_ms` is what the phase lock itself is fed -- see
    /// `getStatus` for why it is a different, round-trip-compensated value.
    fn recordSample(self: *Self, sample_ms: i64, lock_sample_ms: i64, kind: PollKind, run_status: BlurayPlayerRunStatus, play_time: u32) void {
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
        if (!was_playing) self.lock.resumed(lock_sample_ms, play_time);

        self.lock.sampleRunning(lock_sample_ms, kind, play_time);
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
        self.last_rtt_ms = recv_ms - sent_ms;
        // The player read its own clock somewhere inside the request window.
        // The midpoint is the least-biased estimate; timestamping on arrival
        // would bias every sample late by roughly a full round trip.
        const sample_ms = sent_ms + @divFloor(recv_ms - sent_ms, 2);
        // Empirically, the estimator converged cleanly on real hardware but
        // consistently landed behind the true position. Assuming the latency
        // is ordinary network/processing overhead split roughly evenly
        // between the two legs of the round trip, the player actually reads
        // its clock close to when our request *arrives* -- i.e. close to
        // `sample_ms` itself, half the round trip in -- not at `sent_ms`. The
        // interval-intersection math, though, treats `sample_ms` as "the
        // instant the counter reached `value_sec`" (see `sampleRunning`'s
        // `into` calculation), with no separate allowance for the *response*
        // leg still being in flight after that. Shifting the timestamp fed to
        // the lock earlier by half the round trip corrects for exactly that
        // remaining leg, and is algebraically exactly equivalent to adding
        // `last_rtt_ms / 2` to the *value* instead (fully worked through in
        // CLAUDE.md's "Timing accuracy"), without needing `sampleRunning`'s
        // `value_sec: u32` parameter to carry sub-second precision it cannot
        // represent. Only the lock sees this; `sample_ms` itself stays the
        // true midpoint for `last_update_time` and freshness tracking.
        const lock_sample_ms = sample_ms - @divFloor(self.last_rtt_ms, 2);

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
                self.recordSample(sample_ms, lock_sample_ms, kind, play_state, play_time);
            } else {
                self.recordSample(sample_ms, lock_sample_ms, kind, .Stopped, 0);
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

    // An unlocked snapshot still predicts an edge, from the pseudo-anchor at
    // `sampled_ms - 500`. Returning null here (as this once did) meant no tick
    // wake at all while the lock hunted, so line 1's play time was picked up
    // whenever the idle slice next came round -- late, and unevenly. The edge
    // has to be predicted from the same pseudo-anchor `playTimeMillis` uses,
    // or the loop wakes to find nothing changed, or changes with no wake.
    var unlocked = snap;
    unlocked.has_anchor = false;
    unlocked.sampled_ms = 50_500; // counter reached its value around 50_000
    try std.testing.expectEqual(@as(?i64, 51_000), unlocked.nextTickMs(50_500));
    try std.testing.expectEqual(@as(?i64, 51_000), unlocked.nextTickMs(50_999));
    try std.testing.expectEqual(@as(?i64, 52_000), unlocked.nextTickMs(51_000));

    // Still nothing to wake for when the counter is not advancing at all.
    var unlocked_paused = unlocked;
    unlocked_paused.run_status = .Paused;
    try std.testing.expectEqual(@as(?i64, null), unlocked_paused.nextTickMs(50_500));
}

test "a paused snapshot holds, an unlocked playing one keeps advancing" {
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

    // A *playing* player with no anchor yet is a different case, and freezing
    // it (which this once did) is wrong: the counter is still running, so the
    // position only lurched forward when a poll landed, roughly once a second,
    // and sat stale in between. Cues keyed off it fired late and in visible
    // steps until the lock acquired. It extrapolates from the pseudo-anchor at
    // `sampled_ms - 500` instead -- the midpoint of the second the sample could
    // have been taken in, matching `phase_lock.rebase`, so the value does not
    // jump when the lock finally acquires.
    const searching: Snapshot = .{
        .run_status = .Playing,
        .play_time_seconds = 77,
        .has_anchor = false,
        .sampled_ms = 100_500,
    };
    // At the pseudo-anchor itself, still the reported second.
    try std.testing.expectEqual(@as(u32, 77), searching.playTimeSeconds(100_000));
    try std.testing.expectEqual(@as(u32, 77), searching.playTimeSeconds(100_999));
    // And it advances from there rather than sitting at 77 forever.
    try std.testing.expectEqual(@as(u32, 78), searching.playTimeSeconds(101_000));
    try std.testing.expectEqual(@as(u32, 87), searching.playTimeSeconds(110_000));
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
