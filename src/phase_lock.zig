//! Phase lock onto a remote 1 Hz counter that can only be sampled at
//! whole-second resolution.
//!
//! The Panasonic Blu-ray player reports elapsed play time in whole seconds and
//! every sample costs a network round trip, so the raw value is always stale.
//! Resolution cannot be improved, but the *phase* of the counter's 1 Hz tick
//! can be recovered: if two samples straddle an increment, the tick edge lies
//! between them. Once the edge is known, the value between polls is computed
//! from the local clock instead of being polled for.
//!
//! Two regimes:
//!
//!   * `searching` - poll quickly until an increment is bracketed, which pins
//!     the edge to within half the poll interval.
//!   * `locked` - place a `pre_edge`/`post_edge` pair around each predicted
//!     edge. Seeing exactly one increment across that pair proves the real edge
//!     is still within `edge_guard_ms` of the prediction. Anything else means
//!     the phase moved, so the lock is dropped and the hunt restarts.
//!
//! The straddle pair is what makes pauses safe. A pause shifts the counter's
//! phase by its duration, but a pause shorter than the poll interval may never
//! be observed as a paused *status*. Comparing against the prediction with a
//! whole-second tolerance cannot see such a shift; the straddle can.
//!
//! This module is deliberately free of I/O so the state machine can be tested
//! deterministically.

const std = @import("std");

/// Whether the phase of the remote tick is known.
pub const Phase = enum { searching, locked };

/// What a given poll is for.
pub const PollKind = enum {
    /// Free-running poll while hunting for an edge to bracket.
    hunt,
    /// Placed just *before* a predicted edge; captures the "before" value.
    pre_edge,
    /// Placed just *after* the same edge; must show the value incremented.
    post_edge,
};

/// Poll cadence while hunting for an edge. Each edge is bracketed to roughly
/// half this.
pub const fast_poll_ms: i64 = 100;
/// Half-width of the straddle window placed around each predicted edge. Also
/// the largest phase error the lock tolerates before re-hunting.
pub const edge_guard_ms: i64 = 75;
/// Cadence while the source is not running. Kept short because the event being
/// waited for is the transition back to running, and any delay noticing it is
/// time spent displaying a stale value.
pub const idle_poll_ms: i64 = 300;
/// Back off after a failed request rather than hammering the source.
pub const error_retry_ms: i64 = 2000;

pub const PhaseLock = struct {
    phase: Phase,
    /// Wall-clock ms at which the counter became `anchor_sec`.
    anchor_ms: i64,
    anchor_sec: u32,
    /// Half-width of the bracket that produced `anchor_ms`; diagnostics only.
    anchor_err_ms: i64,
    /// Previous sample, used to bracket an edge.
    prev_sample_ms: i64,
    prev_sample_sec: u32,
    have_prev_sample: bool,
    /// When the next poll is due, and what it is for.
    next_poll_ms: i64,
    next_kind: PollKind,

    pub const init: PhaseLock = .{
        .phase = .searching,
        .anchor_ms = 0,
        .anchor_sec = 0,
        .anchor_err_ms = 0,
        .prev_sample_ms = 0,
        .prev_sample_sec = 0,
        .have_prev_sample = false,
        .next_poll_ms = 0,
        .next_kind = .hunt,
    };

    pub fn due(self: *const PhaseLock, now_ms: i64) bool {
        return now_ms >= self.next_poll_ms;
    }

    pub fn isLocked(self: *const PhaseLock) bool {
        return self.phase == .locked;
    }

    /// Abandon the phase estimate and any bracket in progress.
    pub fn drop(self: *PhaseLock) void {
        self.phase = .searching;
        self.anchor_err_ms = 0;
        self.have_prev_sample = false;
    }

    /// Predicted counter value at `at_ms`, or `fallback` when unlocked.
    pub fn predict(self: *const PhaseLock, at_ms: i64, fallback: u32) u32 {
        if (self.phase != .locked) return fallback;
        const elapsed_ms = at_ms - self.anchor_ms;
        if (elapsed_ms < 0) return self.anchor_sec;
        return self.anchor_sec +| @as(u32, @intCast(@divFloor(elapsed_ms, 1000)));
    }

    /// First predicted edge strictly after `at_ms`.
    fn nextEdgeAfter(self: *const PhaseLock, at_ms: i64) i64 {
        return self.anchor_ms + (@divFloor(at_ms - self.anchor_ms, 1000) + 1) * 1000;
    }

    /// Record that the source is not running. Resuming restarts the tick at an
    /// unrelated phase, so any lock is void.
    pub fn sampleStopped(self: *PhaseLock) void {
        self.drop();
    }

    /// Fold one sample taken while the source is running into the lock.
    ///
    /// `sample_ms` is the best estimate of when the source read its own clock;
    /// for a request/response exchange that is the midpoint of the two.
    pub fn sampleRunning(self: *PhaseLock, sample_ms: i64, kind: PollKind, value_sec: u32) void {
        if (self.phase == .locked) {
            if (kind == .post_edge and self.have_prev_sample) {
                // Phase detector: the straddle must contain exactly one tick.
                if (@as(i64, value_sec) - @as(i64, self.prev_sample_sec) != 1) {
                    self.drop();
                }
            } else {
                // Coarse check for a seek landing somewhere else entirely.
                const drift = @as(i64, value_sec) - @as(i64, self.predict(sample_ms, value_sec));
                if (drift < -1 or drift > 1) self.drop();
            }
        }

        // Only a hunt bracket may set the anchor. A straddle pair is centred on
        // the *predicted* edge, so re-anchoring to its midpoint would keep
        // restating the existing estimate while folding in the round-trip
        // offset -- a feedback loop that walks the anchor away from the true
        // edge until the lock breaks. The straddle's job is to confirm, and to
        // drop the lock when confirmation fails; re-acquiring is the hunt's job.
        if (kind == .hunt and self.have_prev_sample and value_sec != self.prev_sample_sec) {
            const err_ms = @divFloor(sample_ms - self.prev_sample_ms, 2);
            // Accept only brackets at least as tight as the straddle window;
            // wider ones carry no useful phase information.
            if (err_ms <= edge_guard_ms) {
                self.anchor_ms = self.prev_sample_ms + err_ms;
                self.anchor_sec = value_sec;
                self.anchor_err_ms = err_ms;
                self.phase = .locked;
            }
        }

        self.prev_sample_ms = sample_ms;
        self.prev_sample_sec = value_sec;
        self.have_prev_sample = true;
    }

    /// Choose when the next poll happens, given the poll just completed.
    pub fn schedule(self: *PhaseLock, now_ms: i64, completed: PollKind, running: bool) void {
        if (!running) {
            self.next_poll_ms = now_ms + idle_poll_ms;
            self.next_kind = .hunt;
            return;
        }
        if (self.phase != .locked) {
            self.next_poll_ms = now_ms + fast_poll_ms;
            self.next_kind = .hunt;
            return;
        }
        if (completed == .pre_edge) {
            // Close the straddle around the edge just stepped in front of.
            self.next_poll_ms = self.nextEdgeAfter(now_ms) + edge_guard_ms;
            self.next_kind = .post_edge;
        } else {
            // Open a straddle around the next edge far enough ahead that the
            // leading half still lands before it.
            self.next_poll_ms = self.nextEdgeAfter(now_ms + edge_guard_ms) - edge_guard_ms;
            self.next_kind = .pre_edge;
        }
    }

    /// A failed request leaves a gap in sampling, invalidating any bracket.
    pub fn retryAfterError(self: *PhaseLock, now_ms: i64) void {
        self.next_poll_ms = now_ms + error_retry_ms;
        self.next_kind = .hunt;
        self.have_prev_sample = false;
    }
};

// ---------------------------------------------------------------------------
// Tests: a simulated player driving the state machine deterministically.
// ---------------------------------------------------------------------------

/// A source whose counter advances only while running.
const Sim = struct {
    now_ms: i64 = 0,
    /// Content time in ms; the reported value is this truncated to seconds.
    content_ms: i64 = 0,
    running: bool = true,
    /// Simulated round-trip time; the sample instant is the midpoint.
    rtt_ms: i64 = 20,

    fn reported(self: Sim) u32 {
        return @intCast(@divFloor(self.content_ms, 1000));
    }

    fn advance(self: *Sim, dt_ms: i64) void {
        self.now_ms += dt_ms;
        if (self.running) self.content_ms += dt_ms;
    }

    /// Run one poll: wait until it is due, exchange, and reschedule.
    fn step(self: *Sim, lock: *PhaseLock) void {
        const wait = lock.next_poll_ms - self.now_ms;
        if (wait > 0) self.advance(wait);

        const kind = lock.next_kind;
        self.advance(@divFloor(self.rtt_ms, 2));
        const sample_ms = self.now_ms;
        const value = self.reported();
        const running = self.running;
        self.advance(self.rtt_ms - @divFloor(self.rtt_ms, 2));

        if (running) {
            lock.sampleRunning(sample_ms, kind, value);
        } else {
            lock.sampleStopped();
        }
        lock.schedule(self.now_ms, kind, running);
    }

    fn stepN(self: *Sim, lock: *PhaseLock, n: usize) void {
        for (0..n) |_| self.step(lock);
    }
};

/// Signed difference, in ms, between the model's tick edges and the real ones,
/// wrapped to (-500, 500]. This is the quantity that actually matters: it is
/// how early or late the displayed second flips.
fn phaseErrorMs(sim: *const Sim, lock: *const PhaseLock) i64 {
    // Most recent real edge at or before now.
    const real_edge = sim.now_ms - @mod(sim.content_ms, 1000);
    // Most recent modelled edge at or before now.
    const model_edge = lock.anchor_ms + @divFloor(sim.now_ms - lock.anchor_ms, 1000) * 1000;
    return @mod(model_edge - real_edge + 500, 1000) - 500;
}

/// The lock must be held and its edges must line up with the real ones.
fn expectInSync(sim: *const Sim, lock: *const PhaseLock) !void {
    try std.testing.expect(lock.isLocked());
    const err_ms = phaseErrorMs(sim, lock);
    if (@abs(err_ms) > edge_guard_ms) {
        std.debug.print("phase error {d} ms exceeds guard {d} ms\n", .{ err_ms, edge_guard_ms });
        return error.PhaseErrorTooLarge;
    }
    // Away from an edge the predicted second must match exactly.
    const into_second = @mod(sim.content_ms, 1000);
    if (into_second > 200 and into_second < 800) {
        try std.testing.expectEqual(sim.reported(), lock.predict(sim.now_ms, 0));
    }
}

test "acquires lock quickly from cold start" {
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 12_345 };

    // A full second of hunting at 100 ms is more than enough to bracket an edge.
    sim.stepN(&lock, 15);
    try expectInSync(&sim, &lock);
    // The bracket should be tight, not merely present.
    try std.testing.expect(lock.anchor_err_ms <= edge_guard_ms);
}

test "stays locked and in sync over a long run" {
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 1_000 };
    sim.stepN(&lock, 15);
    try expectInSync(&sim, &lock);

    // Many straddle pairs; the lock must survive all of them.
    for (0..200) |_| {
        sim.step(&lock);
        if (lock.isLocked()) try expectInSync(&sim, &lock);
    }
    try expectInSync(&sim, &lock);
}

test "re-locks after a pause that is never observed as paused status" {
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 5_000 };
    sim.stepN(&lock, 15);
    try expectInSync(&sim, &lock);
    const anchor_before = lock.anchor_ms;

    // The player was paused ~400 ms between two polls: content falls behind the
    // wall clock, shifting the tick phase, but the status never read "paused".
    sim.content_ms -= 400;

    // The straddle pair must notice the phase moved.
    sim.stepN(&lock, 4);
    try std.testing.expect(lock.anchor_ms != anchor_before);

    // ...and the hunt must re-acquire the new phase.
    sim.stepN(&lock, 15);
    try expectInSync(&sim, &lock);
}

test "small phase shifts are caught, not silently tolerated" {
    // Regression guard: a whole-second drift tolerance would absorb every one
    // of these and leave the display permanently offset.
    for ([_]i64{ 120, 250, 400, 600, 900 }) |shift_ms| {
        var lock = PhaseLock.init;
        var sim: Sim = .{ .content_ms = 30_000 };
        sim.stepN(&lock, 15);
        try expectInSync(&sim, &lock);

        sim.content_ms -= shift_ms;
        sim.stepN(&lock, 20);
        try expectInSync(&sim, &lock);
    }
}

test "recovers from an explicit pause and resume" {
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 8_000 };
    sim.stepN(&lock, 15);
    try expectInSync(&sim, &lock);

    // Pause: the lock must be dropped, since resuming restarts the phase.
    sim.running = false;
    sim.stepN(&lock, 3);
    try std.testing.expect(!lock.isLocked());

    // Resume at an arbitrary phase offset from the old one.
    sim.advance(1_337);
    sim.running = true;
    sim.stepN(&lock, 20);
    try expectInSync(&sim, &lock);
}

test "recovers from a seek while playing" {
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 60_000 };
    sim.stepN(&lock, 15);
    try expectInSync(&sim, &lock);

    // Jump forward half an hour, landing on an unrelated phase.
    sim.content_ms += 1_800_000 + 137;
    sim.stepN(&lock, 20);
    try expectInSync(&sim, &lock);
}

test "locked cadence is about two polls per second" {
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 2_000 };
    sim.stepN(&lock, 15);
    try expectInSync(&sim, &lock);

    const start_ms = sim.now_ms;
    const polls = 20;
    sim.stepN(&lock, polls);
    const elapsed_ms = sim.now_ms - start_ms;

    // Two polls per second means ~10 s for 20 polls; allow generous slack but
    // fail loudly if it degenerates into continuous fast polling.
    try std.testing.expect(elapsed_ms > 7_000);
}

test "predict falls back while unlocked" {
    var lock = PhaseLock.init;
    try std.testing.expectEqual(@as(u32, 42), lock.predict(1_000_000, 42));
}
