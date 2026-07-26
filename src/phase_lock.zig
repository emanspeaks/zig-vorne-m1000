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
//! so the straddle catches what the value check cannot. Either check acts
//! immediately: a phase failure re-hunts, and a value failure `rebase`s the
//! anchor on the spot rather than merely dropping it, since the very sample
//! that caught the mismatch is itself a fresh, trustworthy reading -- dropping
//! without using it would leave the display running from the old, wrong
//! anchor for an entire extra hunt cycle after the true position is already
//! known.
//!
//! Once locked, the anchor is periodically re-hunted to keep it from staying
//! loose forever (`relockIntervalMs`), but how *often* is scaled by how good
//! it already is: a bracket already as tight as `edge_guard_ms` cannot be
//! improved on, so refreshing it on the same short cadence as a loose one
//! would just load the player's small embedded server for no benefit --
//! ordinary drift is caught continuously by the straddle and mid-second checks
//! regardless of refresh cadence, so a tight anchor can safely go much longer
//! between refreshes. A refresh hunt also polls gentler than a cold one
//! (`refresh_hunt_poll_ms` vs. `fast_poll_ms`): a cold hunt has nothing else
//! driving the display and needs to move fast, but a refresh already has a
//! good anchor doing that job throughout, so there is no urgency, only
//! opportunism.
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
/// Hard ceiling on the gap between polls, regardless of what any other part of
/// `schedule` computes. A live source is worth checking on at least this
/// often even when every other heuristic here concludes it can wait longer --
/// trick-play states in particular (rewind, fast-forward) can go unnoticed for
/// a while otherwise, since nothing about them changes `running`.
pub const max_poll_gap_ms: i64 = 1000;
/// Hunt samples to spend chasing a tight bracket before settling for whatever
/// the round trip allows. Hunting is a burst, not a steady state.
pub const hunt_patience: u32 = 40;
/// Widest bracket worth anchoring to at all, once patience has run out.
pub const max_bracket_ms: i64 = 250;
/// Widest the straddle may ever be opened.
///
/// The pair has to sit either side of *one* edge. As the half-width approaches
/// 500 ms it spans the whole second and starts bracketing two, at which point
/// its check fails constantly and thrashes the lock instead of protecting it.
pub const max_guard_ms: i64 = 300;
/// Re-acquire the anchor from scratch this often while it is still loose (its
/// error exceeds `edge_guard_ms`). The straddle only ever confirms the existing
/// estimate and never improves it, so without a refresh a lock taken from a
/// loose bracket -- typically because of a slow round trip -- would stay loose
/// for the rest of the disc.
///
/// A refresh does not drop the lock -- see `refreshing` -- so this can be
/// frequent without the display ever falling back to a raw sample.
pub const relock_interval_loose_ms: i64 = 5_000;
/// Re-acquire the anchor this much less often once it is already tight.
/// Refreshing exists to *improve* the bracket; once it can't improve on a
/// bracket that already meets `edge_guard_ms`, hunting again on the same
/// 5-second cadence buys nothing but load on the player's small embedded
/// server -- ordinary drift is already caught continuously by the straddle and
/// mid-second checks regardless of how often a refresh runs.
pub const relock_interval_tight_ms: i64 = 30_000;
/// Poll cadence for a *refresh* hunt, as opposed to a cold one.
///
/// A cold hunt (no anchor yet, or one just invalidated by a real desync) has
/// nothing to fall back on, so it hunts at `fast_poll_ms` to re-acquire as fast
/// as possible. A refresh hunt is different: the existing anchor is still
/// driving the display correctly the whole time (`refreshing` guarantees this),
/// so there is no urgency, only opportunism -- gentler is fine.
///
/// Not arbitrarily gentle, though: a bracket is only accepted as tight when its
/// half-width, `(sample_gap + rtt) / 2`, is at most `edge_guard_ms`. Slower than
/// this and a refresh can never actually tighten anything -- every cycle falls
/// through to the loose `hunt_patience` fallback, which then immediately
/// re-triggers the *loose*-tier relock interval, turning "gentler" into "runs
/// constantly and never improves," the opposite of the intent. This value
/// leaves headroom for a real round trip on top of the gap and still clears
/// that bar; a value found empirically to still starve tightening will show up
/// as a failure in `expectInSync` during the refresh tests, not silently.
pub const refresh_hunt_poll_ms: i64 = 90;

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
    /// Whether an anchor exists at all, independent of whether its phase is
    /// currently trusted.
    ///
    /// Once the tick has been bracketed even once, the model keeps running from
    /// that anchor -- free-wheeling -- through hunts, refreshes and network
    /// trouble. Only a real discontinuity throws it away. Without this a lost
    /// lock sent the display back to the last raw sample, which changes only
    /// when a poll lands: the clock visibly stalls and then jumps, which is far
    /// worse than coasting on a slightly stale estimate.
    have_anchor: bool,
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
        .have_anchor = false,
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

    /// Whether `predict` has anything to extrapolate from.
    pub fn hasAnchor(self: *const PhaseLock) bool {
        return self.have_anchor;
    }

    /// Stop trusting the phase and hunt for a fresh bracket, while the existing
    /// anchor carries on driving the display.
    ///
    /// Losing the phase does not mean the counter stopped counting, so the best
    /// available estimate is still the old anchor run forward. Discarding it
    /// here would stall the display for the length of the hunt.
    pub fn drop(self: *PhaseLock) void {
        self.phase = .searching;
        self.have_prev_sample = false;
        self.hunt_samples = 0;
        self.refreshing = false;
    }

    /// Throw the anchor away entirely.
    ///
    /// Only for a genuine discontinuity -- the counter stopped or paused --
    /// where nothing about the old model applies any more and free-wheeling
    /// from it would confidently display a time that is simply wrong.
    pub fn reset(self: *PhaseLock) void {
        self.drop();
        self.have_anchor = false;
        self.anchor_err_ms = 0;
    }

    /// Re-point the anchor at a fresh sample without claiming to know the phase.
    ///
    /// For a seek: the counter is still running, but the old anchor's *value*
    /// is now wrong, so free-wheeling from it would show the wrong time.
    /// Anchoring on the sample instant is correct to within a second straight
    /// away, and the hunt tightens the phase from there -- far better than
    /// stalling the display until a new bracket turns up.
    fn rebase(self: *PhaseLock, sample_ms: i64, value_sec: u32) void {
        self.drop();
        // The counter reached `value_sec` at some point in the second *before*
        // the sample, uniformly distributed, so the expected edge is half a
        // second back. Anchoring on the sample instant instead would bias every
        // rebase late by that half second, and since the display jumps by the
        // size of the correction, a biased rebase can skip a short cue outright.
        self.anchor_ms = sample_ms - 500;
        self.anchor_sec = value_sec;
        // The value is right; where inside the second it changes is not known.
        self.anchor_err_ms = 500;
        self.have_anchor = true;
    }

    /// Anchor immediately on the first sample taken after playback resumes
    /// from a stop or a genuine pause.
    ///
    /// The counter restarts at an unrelated phase and often an unrelated
    /// position, so the old anchor's *value* is actively wrong, not merely
    /// untrusted -- `reset` is the correct response to the stop/pause itself.
    /// But calling `reset` again here, on the resume, would leave `predict`
    /// with nothing to extrapolate from for the length of an entire cold hunt,
    /// stalling the display at a flat, unmoving value at exactly the moment
    /// someone is most likely watching it: right after pressing play. Anchoring
    /// on this first sample keeps the clock moving immediately, at the same
    /// +-500 ms precision `rebase` uses for a seek, while the hunt that follows
    /// tightens it. Same operation as `rebase`; named separately because the
    /// two callers reason about it differently and conflating them at the call
    /// site obscured that stalling here was ever a choice rather than a given.
    pub fn resumed(self: *PhaseLock, sample_ms: i64, value_sec: u32) void {
        self.rebase(sample_ms, value_sec);
    }

    /// Predicted counter value at `at_ms`, or `fallback` when there is no
    /// anchor to extrapolate from.
    pub fn predict(self: *const PhaseLock, at_ms: i64, fallback: u32) u32 {
        if (!self.have_anchor) return fallback;
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
        return @min(max_guard_ms, @max(edge_guard_ms, 2 * self.anchor_err_ms));
    }

    /// How long to trust the current anchor before hunting a fresh one.
    ///
    /// Scaled by how good the anchor already is -- the "poll less often the
    /// more precisely the phase is already known" idea, applied directly.
    /// Tight, and a refresh could not improve on it anyway; loose, and it is
    /// still worth trying again soon. Ordinary drift does not depend on this at
    /// all: the straddle and mid-second checks run continuously regardless and
    /// will drop the lock the moment either disagrees with reality. This only
    /// controls how often the bracket gets a chance to *tighten*.
    fn relockIntervalMs(self: *const PhaseLock) i64 {
        return if (self.anchor_err_ms <= edge_guard_ms)
            relock_interval_tight_ms
        else
            relock_interval_loose_ms;
    }

    /// Whether the straddle is worth running at all.
    ///
    /// The pair has to land either side of *one* edge. That needs the guard to
    /// exceed the anchor's own uncertainty while still staying well inside half
    /// a second. On a slow link both cannot hold at once: the guard saturates,
    /// the pair stops bracketing reliably, and its check then fails over and
    /// over, thrashing the lock it exists to protect.
    ///
    /// In that regime the mid-second value check plus periodic re-hunting is
    /// the whole useful mechanism. The phase stays as good as the last hunt
    /// made it, which is all the round trip allows anyway.
    fn straddleUseful(self: *const PhaseLock) bool {
        return 2 * self.anchor_err_ms <= max_guard_ms;
    }

    /// Record that the source is not running. Nothing is counting, and resuming
    /// restarts the tick at an unrelated phase, so the anchor is void rather
    /// than merely untrusted -- there is nothing to free-wheel.
    pub fn sampleStopped(self: *PhaseLock) void {
        self.reset();
    }

    /// Fold one sample taken while the source is running into the lock.
    ///
    /// `sample_ms` is the best estimate of when the source read its own clock;
    /// for a request/response exchange that is the midpoint of the two.
    pub fn sampleRunning(self: *PhaseLock, sample_ms: i64, kind: PollKind, value_sec: u32) void {
        // Checked whenever there is an anchor to check against, not just while
        // `locked`. `.hunt`-kind polls are scheduled exclusively from the
        // *un*-locked branch of `schedule`, so gating this on `phase == .locked`
        // meant `check`'s own `.hunt` case could never run -- provably dead
        // code, not merely redundant. That gap is what let a bad anchor
        // free-wheel forward, unexamined, for as long as a hunt kept failing to
        // re-lock: nothing was watching it. Now every sample -- hunting or not
        // -- gets compared against whatever anchor currently exists.
        if (self.have_anchor) self.check(sample_ms, kind, value_sec);

        // Only a hunt bracket may set the anchor. A straddle pair is centred on
        // the *predicted* edge, so re-anchoring to its midpoint would keep
        // restating the existing estimate while folding in the round-trip
        // offset -- a feedback loop that walks the anchor away from the true
        // edge until the lock breaks. The straddle's job is to confirm, and to
        // drop the lock when confirmation fails; re-acquiring is the hunt's job.
        if (kind == .hunt) {
            // Exactly +1, not merely "changed". A pair of samples straddling a
            // *decreasing* value -- rewind -- or one that jumped by more than
            // one second both produce a "change" too, and the timing-gap check
            // below cannot tell either apart from a genuine tick: the gap is
            // measured in wall-clock time between polls, which stays small
            // regardless of which direction, or how far, the reported value
            // moved. Accepting either as if it were a normal forward edge
            // anchors the model to a fabricated tick pointed the wrong way.
            if (self.have_prev_sample and value_sec == self.prev_sample_sec +| 1) {
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
                    self.have_anchor = true;
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
                //
                // A failure rebases immediately rather than merely dropping,
                // for the same reason as a `mid_second` mismatch: this sample
                // is fresh, trustworthy ground truth regardless of why the
                // straddle count was wrong, and a bare `drop` would leave
                // `predict` free-wheeling from the stale anchor for an entire
                // extra hunt cycle on top of whatever this straddle already
                // caught -- measured, during a sustained rewind, as an extra
                // ~60-90 ms of otherwise-avoidable lag on every single catch.
                if (self.have_prev_sample and
                    @as(i64, value_sec) - @as(i64, self.prev_sample_sec) != 1)
                {
                    self.rebase(sample_ms, value_sec);
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
                //
                // A mismatch is rebased immediately rather than merely dropped.
                // This sample is fresh, trustworthy ground truth -- exactly what
                // `rebase` wants -- so using it now fixes the display on this
                // same pass. A bare `drop` would leave `predict` free-wheeling
                // from the stale, wrong anchor for the length of the ensuing
                // hunt (which can run to a second or more), which is a real,
                // measurable source of the display reading behind the truth:
                // every desync this check catches would otherwise cost an
                // extra hunt's worth of visible lag on top of the desync itself.
                if (value_sec != self.predict(sample_ms, value_sec)) self.rebase(sample_ms, value_sec);
            },
            .hunt, .pre_edge => {
                // Sampled close to an edge, where +/-1 is genuinely ambiguous.
                // Anything beyond that is a seek to somewhere else entirely,
                // which invalidates the anchor's value as well as its phase.
                const drift = @as(i64, value_sec) - @as(i64, self.predict(sample_ms, value_sec));
                if (drift < -1 or drift > 1) self.rebase(sample_ms, value_sec);
            },
        }
    }

    /// Choose when the next poll happens, given the poll just completed.
    pub fn schedule(self: *PhaseLock, now_ms: i64, completed: PollKind, running: bool) void {
        self.scheduleInner(now_ms, completed, running);
        // Never leave a poll further out than `max_poll_gap_ms`, regardless of
        // which branch below fired. Every branch already keeps well inside
        // this in practice -- the arithmetic in `nextEdgeAfter`/`midSecondAfter`
        // cannot itself produce more than ~1000 ms out -- but this is what
        // actually *guarantees* it rather than relying on that remaining true,
        // and it protects against a future scheduling change silently
        // regressing it. Requested explicitly: a stale status must never be
        // allowed to sit unchecked for more than a second, no matter what the
        // rest of this state machine's reasoning concludes is "efficient".
        if (self.next_poll_ms - now_ms > max_poll_gap_ms) {
            self.next_poll_ms = now_ms + max_poll_gap_ms;
        }
    }

    fn scheduleInner(self: *PhaseLock, now_ms: i64, completed: PollKind, running: bool) void {
        if (!running) {
            self.next_poll_ms = now_ms + idle_poll_ms;
            self.next_kind = .hunt;
            return;
        }
        if (self.phase != .locked or self.refreshing) {
            // Back off once the hunt has clearly stopped converging, so a
            // source that never yields a tight bracket is not polled at the
            // hunt rate indefinitely.
            //
            // A refresh hunts gentler than a cold one. A cold hunt (no anchor,
            // or one a real desync just invalidated) has nothing else driving
            // the display, so speed matters more than load. A refresh already
            // has a good anchor doing that job the whole time -- it is purely
            // opportunistic -- so there is no reason to burst it at the same
            // rate and lean on the player's small embedded server for nothing.
            const gap = if (self.hunt_samples >= hunt_patience)
                idle_poll_ms
            else if (self.refreshing)
                refresh_hunt_poll_ms
            else
                fast_poll_ms;
            self.next_poll_ms = now_ms + gap;
            self.next_kind = .hunt;
            return;
        }
        if (now_ms - self.locked_at_ms >= self.relockIntervalMs()) {
            // Start hunting a fresh bracket, but keep the current anchor
            // driving the display until a better one arrives, so a re-sync is
            // invisible rather than a stutter.
            self.refreshing = true;
            self.hunt_samples = 0;
            self.next_poll_ms = now_ms + refresh_hunt_poll_ms;
            self.next_kind = .hunt;
            return;
        }

        // Too loose to straddle: fall back to value checks alone, which stay
        // reliable at any round trip because they are taken far from an edge.
        if (!self.straddleUseful()) {
            self.next_poll_ms = self.midSecondAfter(now_ms);
            self.next_kind = .mid_second;
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
                self.next_poll_ms = self.midSecondAfter(now_ms);
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

    /// The next instant midway between two predicted edges, strictly ahead.
    fn midSecondAfter(self: *const PhaseLock, now_ms: i64) i64 {
        const mid = self.nextEdgeAfter(now_ms) - 500;
        return if (mid > now_ms) mid else mid + 1000;
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
    /// Content-time rate relative to wall-clock time, in thousandths: `1000` is
    /// normal 1x forward playback, `-3000` is a 3x reverse scan (rewind).
    /// `run_status` on a real player has no representation for this -- trick
    /// play still reports "playing" -- so it is a property of how `content_ms`
    /// moves, not of `running`.
    content_rate_permille: i64 = 1000,

    fn reported(self: Sim) u32 {
        return @intCast(@divFloor(self.content_ms, 1000));
    }

    fn advance(self: *Sim, dt_ms: i64) void {
        self.now_ms += dt_ms;
        if (self.running) {
            self.content_ms += @divTrunc(dt_ms * self.content_rate_permille, 1000);
        }
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

    // Three checks per second, plus an occasional gentle refresh burst. The
    // exact average does not matter; what matters is that it stays far below
    // the hunt rate, which would hammer the player's small web server.
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

    // Several refresh intervals' worth of running. A default-rtt lock is tight
    // (well under edge_guard_ms), so the tight-tier interval applies.
    const until_ms = sim.now_ms + 4 * relock_interval_tight_ms;
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

    while (sim.now_ms < first_anchor_at + relock_interval_tight_ms + 3_000) sim.step(&lock);

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
    while (sim.now_ms < first_lock_ms + relock_interval_tight_ms + 5_000) sim.step(&lock);
    try std.testing.expect(lock.locked_at_ms > first_lock_ms);
    try expectInSync(&sim, &lock);
}

test "a tight anchor relaxes its own refresh cadence" {
    // The precision-scaled relock interval, directly: once the bracket is
    // already as good as `edge_guard_ms`, refreshing on the loose (5 s) cadence
    // would buy nothing and just load the player for no reason.
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 5_000 }; // default rtt_ms=20 locks tight
    sim.stepN(&lock, 20);
    try expectInSync(&sim, &lock);

    try std.testing.expect(lock.anchor_err_ms <= edge_guard_ms);
    try std.testing.expectEqual(relock_interval_tight_ms, lock.relockIntervalMs());

    // It must not have refreshed yet at the old, tighter 5 s mark.
    const start_ms = sim.now_ms;
    while (sim.now_ms < start_ms + relock_interval_loose_ms) sim.step(&lock);
    try std.testing.expect(!lock.refreshing);
}

test "a loose anchor keeps trying on the shorter interval" {
    // With a round trip too slow to ever bracket tightly, refreshing is still
    // worth attempting on the original, more frequent cadence -- there is real
    // room to improve, unlike the tight case above.
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 5_000, .rtt_ms = 200 };
    sim.stepN(&lock, hunt_patience + 20);
    try std.testing.expect(lock.isLocked());

    try std.testing.expect(lock.anchor_err_ms > edge_guard_ms);
    try std.testing.expectEqual(relock_interval_loose_ms, lock.relockIntervalMs());
}

test "a refresh hunts gently, not at the cold-start rate" {
    // A refresh already has a good anchor driving the display; there is no
    // urgency, only opportunism, so it must not burst requests at the same
    // rate as a cold hunt starting from nothing.
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 5_000 };
    sim.stepN(&lock, 20);
    try expectInSync(&sim, &lock);

    // Run until a refresh is underway.
    while (!lock.refreshing) sim.step(&lock);

    // The poll just scheduled for this refresh must use the gentle cadence.
    try std.testing.expectEqual(refresh_hunt_poll_ms, lock.next_poll_ms - sim.now_ms);
}

test "mid_second immediately corrects the display, not just the phase" {
    // Regression guard for a real, measured source of "the display reads
    // behind the player": previously a mid-second mismatch only dropped the
    // lock, leaving `predict` running from the old, wrong anchor for an entire
    // extra hunt cycle after the desync was already known about.
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 90_000 };
    sim.stepN(&lock, 20);
    try expectInSync(&sim, &lock);

    // A rewind of a whole number of seconds: phase-preserving, so only the
    // mid-second check can catch it.
    sim.content_ms -= 5_000;

    // Advance until the mismatch is caught (the next mid_second poll).
    while (lock.isLocked()) sim.step(&lock);

    // The very next prediction -- no further polling -- must already be close
    // to the truth, not stuck 5 seconds ahead of it.
    const shown = lock.predict(sim.now_ms, 0);
    const err = @abs(@as(i64, shown) - @as(i64, sim.reported()));
    try std.testing.expect(err <= 1);
}

test "predict falls back only when there is no anchor at all" {
    var lock = PhaseLock.init;
    try std.testing.expectEqual(@as(u32, 42), lock.predict(1_000_000, 42));
}

test "the clock keeps running while the lock is being re-acquired" {
    // The reported failure: during a re-sync the displayed time stalled and
    // then jumped. Losing the phase does not mean the counter stopped counting,
    // so the anchor must keep driving the display through the hunt. Falling
    // back to the last raw sample freezes it until the next poll lands.
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 40_000 };
    sim.stepN(&lock, 20);
    try expectInSync(&sim, &lock);

    // Force the phase to be re-hunted.
    lock.drop();
    try std.testing.expect(!lock.isLocked());
    try std.testing.expect(lock.hasAnchor());

    // Across the whole hunt the prediction must track the truth continuously,
    // never sticking at one value and never going backwards.
    var previous = lock.predict(sim.now_ms, 0);
    var advanced: usize = 0;
    for (0..40) |_| {
        sim.step(&lock);
        const shown = lock.predict(sim.now_ms, 0);
        try std.testing.expect(shown >= previous); // never stalls backwards
        if (shown > previous) advanced += 1;
        // Never more than a second adrift while free-wheeling.
        const truth = sim.reported();
        const err = @abs(@as(i64, shown) - @as(i64, truth));
        try std.testing.expect(err <= 1);
        previous = shown;
    }
    // And it really did keep ticking rather than sitting still.
    try std.testing.expect(advanced >= 2);
    try expectInSync(&sim, &lock);
}

test "resumed anchors immediately rather than stalling like a bare reset" {
    // Regression guard for the reported symptom: after a stop/pause the anchor
    // is correctly gone (`reset`), but resuming used to call `reset` a second
    // time, leaving `predict` with nothing to show -- a flat, unmoving value --
    // for the length of an entire cold hunt right as playback restarted.
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 10_000 };
    sim.stepN(&lock, 20);
    try expectInSync(&sim, &lock);

    lock.reset();
    try std.testing.expect(!lock.hasAnchor());

    // Resume at an arbitrary new position and phase.
    const resume_sample_ms: i64 = sim.now_ms + 5_000;
    const resume_value: u32 = 500;
    lock.resumed(resume_sample_ms, resume_value);

    // Unlike a bare cold start, there is immediately something to show, and it
    // reflects the new position right away rather than the stale old one.
    try std.testing.expect(lock.hasAnchor());
    try std.testing.expectEqual(resume_value, lock.predict(resume_sample_ms, 0));

    // And the clock actually advances from there while the hunt tightens it,
    // rather than sitting flat.
    var advanced = false;
    var t = resume_sample_ms;
    while (t < resume_sample_ms + 3_000) : (t += 100) {
        if (lock.predict(t, 0) > resume_value) advanced = true;
    }
    try std.testing.expect(advanced);
}

test "a stop discards the anchor rather than free-wheeling past it" {
    // Free-wheeling is only right while the counter is actually counting. A
    // stopped player is not, so coasting would confidently show a time that is
    // simply wrong.
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 12_000 };
    sim.stepN(&lock, 20);
    try std.testing.expect(lock.hasAnchor());

    lock.sampleStopped();
    try std.testing.expect(!lock.hasAnchor());
    try std.testing.expectEqual(@as(u32, 99), lock.predict(sim.now_ms, 99));
}

test "a seek re-bases the anchor instead of stalling the display" {
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 100_000 };
    sim.stepN(&lock, 20);
    try expectInSync(&sim, &lock);

    // Jump somewhere unrelated. The anchor's value is now wrong, so it must be
    // re-pointed at the new position -- but it must still have one, so the
    // clock keeps moving while the phase is re-hunted.
    sim.content_ms += 900_000 + 321;
    sim.stepN(&lock, 3);
    try std.testing.expect(lock.hasAnchor());
    const shown = lock.predict(sim.now_ms, 0);
    const err = @abs(@as(i64, shown) - @as(i64, sim.reported()));
    try std.testing.expect(err <= 1);

    sim.stepN(&lock, 30);
    try expectInSync(&sim, &lock);
}

test "a hunt bracket requires an exact +1 tick, not merely a changed value" {
    // Directly exercises the bug: two consecutive hunt samples where the value
    // fell must never be accepted as if they had bracketed a normal forward
    // edge, even though the sample-timing gap is a normal, tight hunt
    // interval -- exactly what the old (timing-only) check would have
    // accepted. Constructed by hand rather than via Sim, since this is testing
    // the acceptance rule in isolation.
    var lock = PhaseLock.init;

    lock.sampleRunning(1_000, .hunt, 100);
    try std.testing.expect(!lock.isLocked());

    // 60 ms later (a normal hunt interval), the value *fell* to 95 -- a
    // rewind-shaped change with an easily-tight-enough timing gap.
    lock.sampleRunning(1_060, .hunt, 95);
    try std.testing.expect(!lock.isLocked());
    try std.testing.expect(!lock.hasAnchor());

    // A genuine +1 at the same tight spacing must still be accepted, so the
    // fix is "require exactly +1", not "never lock".
    lock.sampleRunning(1_120, .hunt, 96);
    try std.testing.expect(lock.isLocked());
    try std.testing.expectEqual(@as(u32, 96), lock.anchor_sec);
}

test "a sustained rewind is tracked, not stuck extrapolating forward" {
    // The reported failure: pressing rewind, the panel just kept counting
    // *up* as though nothing had happened. Two bugs combined to cause it:
    //
    //   1. hunt-bracket acceptance only checked that the value *changed*
    //      between two samples, not that it changed by exactly +1 -- so a
    //      pair straddling a *decreasing* value could be accepted as a normal
    //      forward tick, anchoring the model backward and then extrapolating
    //      it forward from there.
    //   2. the anchor was only ever re-checked against fresh samples while
    //      `locked` -- never while hunting -- so even once hunting correctly
    //      failed to find a new (bogus) bracket, the stale anchor from (1)
    //      kept free-wheeling forward, unexamined, for as long as the hunt
    //      continued to find nothing.
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 60_000 };
    sim.stepN(&lock, 20);
    try expectInSync(&sim, &lock);

    // Rewind at 3x for several seconds.
    sim.content_rate_permille = -3000;

    var ever_had_anchor = false;
    for (0..40) |_| {
        sim.step(&lock);
        if (lock.hasAnchor()) ever_had_anchor = true;

        // The critical property: the shown value must track the true,
        // falling position, not run away from it. Old behaviour would show
        // this error growing roughly linearly with elapsed rewind time (tens
        // of seconds within a few real seconds); a tracking implementation
        // re-anchors within about one hunt interval of drifting past the
        // tolerance `check` enforces, keeping the error to at most 1.
        if (lock.hasAnchor()) {
            const shown = lock.predict(sim.now_ms, sim.reported());
            const err = @abs(@as(i64, shown) - @as(i64, sim.reported()));
            try std.testing.expect(err <= 1);
        }
    }
    try std.testing.expect(ever_had_anchor);
}

test "schedule never leaves a gap wider than max_poll_gap_ms" {
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 60_000, .rtt_ms = 200 };

    // A wide spread of conditions: cold hunt, locked steady state, refresh,
    // idle. None of it should ever produce a scheduled gap over the cap.
    for (0..300) |i| {
        if (i == 100) sim.running = false;
        if (i == 130) sim.running = true;
        if (i == 200) sim.content_ms += 500_000; // seek
        sim.step(&lock);
        try std.testing.expect(lock.next_poll_ms - sim.now_ms <= max_poll_gap_ms);
    }
}

test "the straddle never opens wider than it can bracket one edge" {
    // A half-width approaching 500 ms spans the whole second and starts
    // bracketing two edges, at which point the check fails every time and
    // thrashes the lock instead of protecting it.
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 8_000, .rtt_ms = 250 };

    sim.stepN(&lock, hunt_patience + 40);
    try std.testing.expect(lock.guardMs() <= max_guard_ms);
    try std.testing.expect(lock.guardMs() < 500);

    // Even at this round trip it must hold a lock most of the time rather than
    // oscillating between locked and hunting.
    var locked_polls: usize = 0;
    for (0..200) |_| {
        sim.step(&lock);
        if (lock.isLocked()) locked_polls += 1;
    }
    try std.testing.expect(locked_polls * 100 / 200 >= 70);
}
