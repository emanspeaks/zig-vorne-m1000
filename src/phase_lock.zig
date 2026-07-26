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
//!   * `locked` - three polls per second, each answering a different question:
//!
//!       - `pre_edge` / `post_edge` straddle the predicted edge. Seeing exactly
//!         one increment across the pair proves the *phase* is still right.
//!       - `mid_second` lands midway between two edges and compares the
//!         reported value against the prediction. That proves the *value* is
//!         still right.
//!
//! Both checks are needed, and this is the subtle part. A pause shifts playback
//! backwards by its duration. If that shift is close to a whole number of
//! seconds, the tick phase is left untouched -- both straddle samples move
//! together -- so the phase detector sees a perfect lock while the displayed
//! time is a whole second wrong. Only a sample taken far from any edge, where
//! there is no rounding ambiguity to hide behind, can catch it. Conversely a
//! sub-second shift moves the phase but not the reported value at mid-second,
//! so the straddle catches what the value check cannot.
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
    /// Placed midway between two edges, as far from both as the second allows.
    /// Its reported value must equal the prediction exactly. This is the only
    /// check that can see a shift of a whole second, which leaves the tick
    /// phase -- and therefore the straddle pair -- looking perfectly correct.
    mid_second,
};

/// Poll cadence while hunting for an edge. Each edge is bracketed to roughly
/// half this, so it also sets how tight a fresh lock can be.
pub const fast_poll_ms: i64 = 60;
/// Half-width of the straddle window placed around each predicted edge. Also
/// the largest phase error the lock tolerates before re-hunting.
pub const edge_guard_ms: i64 = 75;
/// Cadence while the source is not running. Kept short because the event being
/// waited for is the transition back to running, and any delay noticing it is
/// time spent displaying a stale value.
pub const idle_poll_ms: i64 = 200;
/// Back off after a failed request rather than hammering the source.
pub const error_retry_ms: i64 = 2000;
/// Hunt samples to spend chasing a tight bracket before settling for whatever
/// the round trip allows. Hunting is a burst, not a steady state.
pub const hunt_patience: u32 = 40;
/// Widest bracket worth anchoring to at all, once patience has run out.
pub const max_bracket_ms: i64 = 400;
/// Re-acquire the anchor from scratch this often. The straddle only ever
/// confirms the existing estimate and never improves it, so without this a lock
/// taken from a loose bracket would stay loose for the rest of the disc, and
/// slow drift between the two clocks would never be corrected.
///
/// A refresh does not drop the lock -- see `refreshing` -- so this can be
/// frequent without the display ever falling back to a raw sample.
pub const relock_interval_ms: i64 = 5_000;

pub const PhaseLock = struct {
    phase: Phase,
    /// Wall-clock ms at which the counter became `anchor_sec`.
    anchor_ms: i64,
    anchor_sec: u32,
    /// Half-width of the bracket that produced `anchor_ms`: how uncertain the
    /// anchor is, which also sets how wide the straddle has to be.
    anchor_err_ms: i64,
    /// When the current anchor was acquired, for periodic re-acquisition.
    locked_at_ms: i64,
    /// Hunting for a fresh bracket while still locked.
    ///
    /// A periodic re-sync must not drop the lock. Dropping it would send
    /// `predict` back to the last raw sample for the length of the hunt, and
    /// the display would visibly stutter every time it re-synced. Instead the
    /// existing anchor keeps driving the display while a new one is hunted, and
    /// is replaced only once there is something better to replace it with.
    refreshing: bool,
    /// Previous sample, used to bracket an edge.
    prev_sample_ms: i64,
    prev_sample_sec: u32,
    have_prev_sample: bool,
    /// Hunt samples taken since the lock was last dropped.
    hunt_samples: u32,
    /// When the next poll is due, and what it is for.
    next_poll_ms: i64,
    next_kind: PollKind,

    pub const init: PhaseLock = .{
        .phase = .searching,
        .anchor_ms = 0,
        .anchor_sec = 0,
        .anchor_err_ms = 0,
        .locked_at_ms = 0,
        .refreshing = false,
        .prev_sample_ms = 0,
        .prev_sample_sec = 0,
        .have_prev_sample = false,
        .hunt_samples = 0,
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
        self.hunt_samples = 0;
        self.refreshing = false;
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

    /// Half-width of the straddle placed around each predicted edge.
    ///
    /// Widened when the anchor itself is loose, so the pair still lands either
    /// side of the true edge instead of failing its own check every time and
    /// thrashing the lock.
    ///
    /// Twice the bracket error is the right amount, and not arbitrary. The
    /// straddle has to absorb two things: the anchor may be off by up to
    /// `anchor_err_ms`, and each sample is taken about half a round trip *after*
    /// the moment it was scheduled for, since `schedule` works in request-start
    /// time. Because a bracket spans one poll gap plus one round trip,
    /// `2 * anchor_err_ms` equals `gap + rtt`, which covers `anchor_err_ms +
    /// rtt/2` for any non-negative gap.
    fn guardMs(self: *const PhaseLock) i64 {
        return @max(edge_guard_ms, 2 * self.anchor_err_ms);
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
        if (self.phase == .locked) self.check(sample_ms, kind, value_sec);

        // Only a hunt bracket may set the anchor. A straddle pair is centred on
        // the *predicted* edge, so re-anchoring to its midpoint would keep
        // restating the existing estimate while folding in the round-trip
        // offset -- a feedback loop that walks the anchor away from the true
        // edge until the lock breaks. The straddle's job is to confirm, and to
        // drop the lock when confirmation fails; re-acquiring is the hunt's job.
        if (kind == .hunt) {
            if (self.have_prev_sample and value_sec != self.prev_sample_sec) {
                const err_ms = @divFloor(sample_ms - self.prev_sample_ms, 2);
                // Hold out for a tight bracket at first, but not forever. When
                // the round trip is slow or jittery enough to keep hunt samples
                // further apart than the guard, a loose anchor still tracks the
                // tick far better than the unlocked fallback, which shows a raw
                // sample stale by a whole poll interval.
                const limit = if (self.hunt_samples >= hunt_patience) max_bracket_ms else edge_guard_ms;
                if (err_ms <= limit) {
                    self.anchor_ms = self.prev_sample_ms + err_ms;
                    self.anchor_sec = value_sec;
                    self.anchor_err_ms = err_ms;
                    self.locked_at_ms = sample_ms;
                    self.phase = .locked;
                    self.refreshing = false;
                    self.hunt_samples = 0;
                }
            }
            self.hunt_samples +|= 1;
        }

        self.prev_sample_ms = sample_ms;
        self.prev_sample_sec = value_sec;
        self.have_prev_sample = true;
    }

    /// Test one sample against the model, dropping the lock when they disagree.
    fn check(self: *PhaseLock, sample_ms: i64, kind: PollKind, value_sec: u32) void {
        switch (kind) {
            .post_edge => {
                // Phase detector: the straddle must contain exactly one tick.
                if (self.have_prev_sample and
                    @as(i64, value_sec) - @as(i64, self.prev_sample_sec) != 1)
                {
                    self.drop();
                }
            },
            .mid_second => {
                // Value detector, taken as far from an edge as the second
                // allows. There is no rounding ambiguity here, so the reported
                // second must equal the predicted one exactly.
                //
                // This is what catches a pause or seek that moved playback by a
                // whole second. The straddle cannot: such a shift moves both of
                // its samples together, leaving the phase looking perfect while
                // the displayed value is a full second out.
                if (value_sec != self.predict(sample_ms, value_sec)) self.drop();
            },
            .hunt, .pre_edge => {
                // Sampled close to an edge, where +/-1 is genuinely ambiguous.
                // Anything beyond that is a seek to somewhere else entirely.
                const drift = @as(i64, value_sec) - @as(i64, self.predict(sample_ms, value_sec));
                if (drift < -1 or drift > 1) self.drop();
            },
        }
    }

    /// Choose when the next poll happens, given the poll just completed.
    pub fn schedule(self: *PhaseLock, now_ms: i64, completed: PollKind, running: bool) void {
        if (!running) {
            self.next_poll_ms = now_ms + idle_poll_ms;
            self.next_kind = .hunt;
            return;
        }
        if (self.phase != .locked or self.refreshing) {
            // Back off once the hunt has clearly stopped converging, so a
            // source that never yields a tight bracket is not polled at the
            // hunt rate indefinitely.
            const gap = if (self.hunt_samples >= hunt_patience) idle_poll_ms else fast_poll_ms;
            self.next_poll_ms = now_ms + gap;
            self.next_kind = .hunt;
            return;
        }
        if (now_ms - self.locked_at_ms >= relock_interval_ms) {
            // Start hunting a fresh bracket, but keep the current anchor
            // driving the display until a better one arrives, so a re-sync is
            // invisible rather than a stutter.
            self.refreshing = true;
            self.hunt_samples = 0;
            self.next_poll_ms = now_ms + fast_poll_ms;
            self.next_kind = .hunt;
            return;
        }

        const guard = self.guardMs();
        switch (completed) {
            .pre_edge => {
                // Close the straddle around the edge just stepped in front of.
                self.next_poll_ms = self.nextEdgeAfter(now_ms) + guard;
                self.next_kind = .post_edge;
            },
            .post_edge => {
                // Then check the value from the quietest point in the second.
                var mid = self.nextEdgeAfter(now_ms) - 500;
                if (mid <= now_ms) mid += 1000;
                self.next_poll_ms = mid;
                self.next_kind = .mid_second;
            },
            .hunt, .mid_second => {
                // Open a straddle around the next edge far enough ahead that
                // the leading half still lands before it.
                self.next_poll_ms = self.nextEdgeAfter(now_ms + guard) - guard;
                self.next_kind = .pre_edge;
            },
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

/// The lock must be held, its edges must line up with the real ones, and -- the
/// part that actually reaches the display -- the predicted second must be the
/// real one, not a whole second out.
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

    // A full second of hunting is more than enough to bracket an edge.
    sim.stepN(&lock, 20);
    try expectInSync(&sim, &lock);
    // The bracket should be tight, not merely present.
    try std.testing.expect(lock.anchor_err_ms <= edge_guard_ms);
}

test "stays locked and in sync over a long run" {
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 1_000 };
    sim.stepN(&lock, 20);
    try expectInSync(&sim, &lock);

    // Many check cycles; the lock must survive all of them.
    for (0..300) |_| {
        sim.step(&lock);
        if (lock.isLocked()) try expectInSync(&sim, &lock);
    }
    try expectInSync(&sim, &lock);
}

test "re-locks after a pause that is never observed as paused status" {
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 5_000 };
    sim.stepN(&lock, 20);
    try expectInSync(&sim, &lock);
    const anchor_before = lock.anchor_ms;

    // The player was paused ~400 ms between two polls: content falls behind the
    // wall clock, shifting the tick phase, but the status never read "paused".
    sim.content_ms -= 400;

    // The straddle pair must notice the phase moved.
    sim.stepN(&lock, 6);
    try std.testing.expect(lock.anchor_ms != anchor_before);

    // ...and the hunt must re-acquire the new phase.
    sim.stepN(&lock, 20);
    try expectInSync(&sim, &lock);
}

test "whole-second shifts are caught, not hidden by an intact phase" {
    // Regression guard for the real failure: pausing or rewinding by close to a
    // whole number of seconds leaves the tick phase perfect, so the straddle is
    // happy while the display sits a full second out. Only the mid-second value
    // check can see this.
    for ([_]i64{ 1000, 2000, 5000, 1005, 995, -1000, -3000 }) |shift_ms| {
        var lock = PhaseLock.init;
        var sim: Sim = .{ .content_ms = 90_000 };
        sim.stepN(&lock, 20);
        try expectInSync(&sim, &lock);

        sim.content_ms -= shift_ms;

        // It must be detected and re-acquired, not silently tolerated.
        sim.stepN(&lock, 30);
        try expectInSync(&sim, &lock);
    }
}

test "small phase shifts are caught, not silently tolerated" {
    // A whole-second drift tolerance would absorb every one of these and leave
    // the display permanently offset.
    for ([_]i64{ 120, 250, 400, 600, 900 }) |shift_ms| {
        var lock = PhaseLock.init;
        var sim: Sim = .{ .content_ms = 30_000 };
        sim.stepN(&lock, 20);
        try expectInSync(&sim, &lock);

        sim.content_ms -= shift_ms;
        sim.stepN(&lock, 30);
        try expectInSync(&sim, &lock);
    }
}

test "recovers from an explicit pause and resume" {
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 8_000 };
    sim.stepN(&lock, 20);
    try expectInSync(&sim, &lock);

    // Pause: the lock must be dropped, since resuming restarts the phase.
    sim.running = false;
    sim.stepN(&lock, 3);
    try std.testing.expect(!lock.isLocked());

    // Resume at an arbitrary phase offset from the old one.
    sim.advance(1_337);
    sim.running = true;
    sim.stepN(&lock, 25);
    try expectInSync(&sim, &lock);
}

test "recovers from a pause and resume that lands on the same phase" {
    // Pausing for a whole number of seconds is the case that used to survive:
    // the resumed tick lines up with the old model exactly, so nothing about
    // the phase looks wrong -- but every reported value is now lower.
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 45_000 };
    sim.stepN(&lock, 20);
    try expectInSync(&sim, &lock);

    sim.running = false;
    sim.advance(4_000); // exactly four seconds, phase preserved
    sim.running = true;

    sim.stepN(&lock, 30);
    try expectInSync(&sim, &lock);
}

test "recovers from a seek while playing" {
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 60_000 };
    sim.stepN(&lock, 20);
    try expectInSync(&sim, &lock);

    // Jump forward half an hour, landing on an unrelated phase.
    sim.content_ms += 1_800_000 + 137;
    sim.stepN(&lock, 30);
    try expectInSync(&sim, &lock);
}

test "recovers from a rewind of a whole number of seconds" {
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 600_000 };
    sim.stepN(&lock, 20);
    try expectInSync(&sim, &lock);

    // Rewind exactly 30 s: large, but phase-preserving, so the straddle alone
    // would never notice.
    sim.content_ms -= 30_000;
    sim.stepN(&lock, 30);
    try expectInSync(&sim, &lock);
}

test "locked cadence stays modest rather than degenerating into fast polling" {
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 2_000 };
    sim.stepN(&lock, 20);
    try expectInSync(&sim, &lock);

    const start_ms = sim.now_ms;
    const polls = 60;
    sim.stepN(&lock, polls);
    const elapsed_ms = sim.now_ms - start_ms;

    // Three checks per second, plus a hunt burst every `relock_interval_ms`.
    // The exact average does not matter; what matters is that it stays far
    // below the hunt rate, which would hammer the player's small web server.
    const per_second = @divFloor(polls * 1000, elapsed_ms);
    try std.testing.expect(per_second >= 3);
    try std.testing.expect(per_second <= 8);
}

test "a periodic refresh never drops the lock" {
    // The refresh exists to keep the anchor fresh, but dropping the lock to do
    // it would send `predict` back to the last raw sample for the length of the
    // hunt -- a visible stutter every few seconds, which is worse than the
    // staleness it set out to fix.
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 20_000 };
    sim.stepN(&lock, 20);
    try expectInSync(&sim, &lock);

    var refreshes_seen: usize = 0;
    var was_refreshing = false;

    // Several refresh intervals' worth of running.
    const until_ms = sim.now_ms + 4 * relock_interval_ms;
    while (sim.now_ms < until_ms) {
        sim.step(&lock);
        if (lock.refreshing and !was_refreshing) refreshes_seen += 1;
        was_refreshing = lock.refreshing;

        // The invariant: locked at every single point along the way.
        try expectInSync(&sim, &lock);
    }

    // And the refreshes really did happen, so the test is not vacuous.
    try std.testing.expect(refreshes_seen >= 3);
}

test "a refresh re-anchors rather than merely restating the old estimate" {
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 7_000 };
    sim.stepN(&lock, 20);
    try expectInSync(&sim, &lock);
    const first_anchor_at = lock.locked_at_ms;

    while (sim.now_ms < first_anchor_at + relock_interval_ms + 3_000) sim.step(&lock);

    try std.testing.expect(lock.locked_at_ms > first_anchor_at);
    try std.testing.expect(!lock.refreshing);
    try expectInSync(&sim, &lock);
}

test "a slow round trip still produces a lock rather than hunting forever" {
    // With a 200 ms round trip no hunt bracket can ever be as tight as the
    // guard. Giving up entirely would leave the display on the raw sample, so
    // the lock must settle for the best bracket available.
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 3_000, .rtt_ms = 200 };

    sim.stepN(&lock, hunt_patience + 20);
    try std.testing.expect(lock.isLocked());
    try std.testing.expect(lock.anchor_err_ms <= max_bracket_ms);

    // And having settled, it must stop polling at the hunt rate.
    const start_ms = sim.now_ms;
    sim.stepN(&lock, 20);
    try std.testing.expect(sim.now_ms - start_ms > 3_000);
}

test "the anchor is re-acquired periodically rather than trusted forever" {
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 10_000 };
    sim.stepN(&lock, 20);
    try expectInSync(&sim, &lock);
    const first_lock_ms = lock.locked_at_ms;

    // Run past the re-lock interval; the anchor must have been rebuilt.
    while (sim.now_ms < first_lock_ms + relock_interval_ms + 5_000) sim.step(&lock);
    try std.testing.expect(lock.locked_at_ms > first_lock_ms);
    try expectInSync(&sim, &lock);
}

test "predict falls back while unlocked" {
    var lock = PhaseLock.init;
    try std.testing.expectEqual(@as(u32, 42), lock.predict(1_000_000, 42));
}
