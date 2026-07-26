//! Minimal WebVTT reader, enough to drive a single 20-column display line.
//!
//! WebVTT was picked over the SMPTE timed-text family (ST 2052-1 and the W3C
//! TTML/IMSC profiles it belongs to) because those are XML: standards-correct
//! but verbose, and these cue files are meant to be written and edited by hand
//! in a text editor. It was picked over SubRip because it has a comment syntax
//! (`NOTE`) and does not demand a sequence number on every cue.
//!
//! Supported subset:
//!
//!   * the `WEBVTT` signature line, with any trailing text taken as a title
//!   * `NOTE`, `STYLE` and `REGION` blocks, skipped
//!   * cues with an optional identifier line, `HH:MM:SS.mmm` or `MM:SS.mmm`
//!     timestamps, and cue settings after the end timestamp (ignored)
//!   * payloads spanning several lines, flattened onto one
//!   * inline tags (`<b>`, `<v Name>`, karaoke timestamps) stripped, and the
//!     entity escapes WebVTT defines decoded
//!
//! Not supported, because one line of characters cannot express any of it:
//! positioning, regions, and styling.
//!
//! A malformed block is skipped rather than failing the whole file: a typo in
//! one cue should not blank the display for a whole movie.

const std = @import("std");

pub const Cue = struct {
    start_ms: i64,
    /// Exclusive: a cue covers `[start_ms, end_ms)`.
    end_ms: i64,
    text: []const u8,
    /// Whether text too wide for the display may scroll.
    ///
    /// False for a payload written with a leading `*`: a warning line, which
    /// has to be readable at a glance rather than over the course of a sweep,
    /// so it is truncated instead. The `*` stays in `text` -- it is part of how
    /// the line reads on the panel, marking it out as special, not just a
    /// parsing directive.
    scroll: bool,
};

/// A parsed cue file. Every slice inside points into `arena`.
///
/// The arena is held by pointer, as `std.json.Parsed` does, so the struct can
/// be moved and copied freely without invalidating the allocator interface.
pub const CueList = struct {
    arena: *std.heap.ArenaAllocator,
    /// Sorted by `start_ms`.
    cues: []const Cue,
    /// Text following the `WEBVTT` signature, if any. Usable as a label.
    title: []const u8,

    pub fn deinit(self: CueList) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }

    /// The cue covering `t_ms`, or null when there is none.
    ///
    /// Overlapping cues are legal in WebVTT but meaningless on a single line,
    /// so the latest-starting cue that is still open wins.
    pub fn at(self: CueList, t_ms: i64) ?Cue {
        var found: ?Cue = null;
        for (self.cues) |cue| {
            // Sorted by start, so once a cue starts in the future nothing
            // after it can be active either.
            if (cue.start_ms > t_ms) break;
            if (t_ms < cue.end_ms) found = cue;
        }
        return found;
    }
};

pub const ParseError = error{NotWebVtt} || std.mem.Allocator.Error;

pub fn parse(child_allocator: std.mem.Allocator, source: []const u8) ParseError!CueList {
    const arena = try child_allocator.create(std.heap.ArenaAllocator);
    errdefer child_allocator.destroy(arena);
    arena.* = .init(child_allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var lines: LineIter = .{ .rest = stripBom(source) };

    // The signature must be the very first line. Anything else is not a WebVTT
    // file, and guessing at it would only produce a display full of noise.
    const signature = std.mem.trim(u8, lines.next() orelse return error.NotWebVtt, " \t");
    const after_signature = blockKeyword(signature, "WEBVTT") orelse return error.NotWebVtt;
    const title = try a.dupe(u8, std.mem.trim(u8, after_signature, " \t"));

    var cues: std.ArrayList(Cue) = .empty;

    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0) continue; // blank separator between blocks

        // Non-cue blocks. `NOTE` is the comment form; the other two carry CSS
        // and region definitions that have no meaning on a character display.
        if (blockKeyword(line, "NOTE") != null or
            blockKeyword(line, "STYLE") != null or
            blockKeyword(line, "REGION") != null)
        {
            lines.skipBlock();
            continue;
        }

        // A cue is either a timing line, or an identifier line followed by one.
        var timing = line;
        if (std.mem.indexOf(u8, timing, "-->") == null) {
            const after_id = lines.next() orelse break;
            timing = std.mem.trim(u8, after_id, " \t");
            if (std.mem.indexOf(u8, timing, "-->") == null) {
                lines.skipBlock();
                continue;
            }
        }

        const span = parseTiming(timing) catch {
            lines.skipBlock();
            continue;
        };

        var text: std.ArrayList(u8) = .empty;
        while (lines.next()) |payload_line| {
            const payload = std.mem.trim(u8, payload_line, " \t");
            if (payload.len == 0) break;
            if (text.items.len > 0) try text.append(a, ' ');
            try appendPayload(a, &text, payload);
        }

        // A payload beginning with `*` is a warning line: it has to be readable
        // at a glance, so it is never scrolled. The marker itself stays in the
        // text, since it is what marks the line out as special on the panel.
        const cue_text = try text.toOwnedSlice(a);
        const scroll = cue_text.len == 0 or cue_text[0] != '*';

        try cues.append(a, .{
            .start_ms = span.start_ms,
            .end_ms = span.end_ms,
            .text = cue_text,
            .scroll = scroll,
        });
    }

    // Cues are conventionally in order already, but `at` relies on it, so
    // do not take the file's word for it.
    std.mem.sort(Cue, cues.items, {}, lessThanStart);

    return .{
        .arena = arena,
        .cues = try cues.toOwnedSlice(a),
        .title = title,
    };
}

fn lessThanStart(_: void, a: Cue, b: Cue) bool {
    return a.start_ms < b.start_ms;
}

fn stripBom(source: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) source[3..] else source;
}

/// If `line` opens a block introduced by `keyword`, the remainder of the line;
/// otherwise null. WebVTT requires the keyword to be followed by whitespace or
/// end of line, so `NOTEBOOK` is not a `NOTE`.
fn blockKeyword(line: []const u8, keyword: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, keyword)) return null;
    const rest = line[keyword.len..];
    if (rest.len == 0) return rest;
    return switch (rest[0]) {
        ' ', '\t' => rest[1..],
        else => null,
    };
}

const LineIter = struct {
    rest: []const u8,
    done: bool = false,

    fn next(self: *LineIter) ?[]const u8 {
        if (self.done) return null;
        if (std.mem.indexOfScalar(u8, self.rest, '\n')) |nl| {
            const line = self.rest[0..nl];
            self.rest = self.rest[nl + 1 ..];
            return std.mem.trimEnd(u8, line, "\r");
        }
        self.done = true;
        return std.mem.trimEnd(u8, self.rest, "\r");
    }

    /// Consume the remainder of the current block, up to and including the
    /// blank line that ends it.
    fn skipBlock(self: *LineIter) void {
        while (self.next()) |line| {
            if (std.mem.trim(u8, line, " \t").len == 0) return;
        }
    }
};

const Span = struct { start_ms: i64, end_ms: i64 };

fn parseTiming(line: []const u8) !Span {
    const arrow = std.mem.indexOf(u8, line, "-->") orelse return error.InvalidTiming;
    const start = std.mem.trim(u8, line[0..arrow], " \t");
    var end = std.mem.trim(u8, line[arrow + 3 ..], " \t");
    // Cue settings (`align`, `position`, `line`, ...) follow the end timestamp,
    // separated by whitespace. None of them mean anything here.
    if (std.mem.indexOfAny(u8, end, " \t")) |sp| end = end[0..sp];

    const span: Span = .{
        .start_ms = try parseTimestamp(start),
        .end_ms = try parseTimestamp(end),
    };
    if (span.end_ms < span.start_ms) return error.InvalidTiming;
    return span;
}

/// Parse `[HH:]MM:SS.mmm`.
///
/// WebVTT separates the fraction with `.` and SubRip with `,`; files get copied
/// between the two often enough that accepting either is worth the one line.
fn parseTimestamp(s: []const u8) !i64 {
    var hms = s;
    var ms: i64 = 0;
    if (std.mem.indexOfAny(u8, s, ".,")) |dot| {
        const frac = s[dot + 1 ..];
        if (frac.len == 0 or frac.len > 3) return error.InvalidTimestamp;
        var scaled = std.fmt.parseInt(i64, frac, 10) catch return error.InvalidTimestamp;
        // ".5" is 500 ms, not 5 ms.
        for (frac.len..3) |_| scaled *= 10;
        hms = s[0..dot];
        ms = scaled;
    }

    var parts: [3]i64 = @splat(0);
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, hms, ':');
    while (it.next()) |part| {
        if (n == parts.len) return error.InvalidTimestamp;
        parts[n] = std.fmt.parseInt(i64, std.mem.trim(u8, part, " \t"), 10) catch
            return error.InvalidTimestamp;
        n += 1;
    }

    return switch (n) {
        2 => parts[0] * std.time.ms_per_min + parts[1] * std.time.ms_per_s + ms,
        3 => parts[0] * std.time.ms_per_hour + parts[1] * std.time.ms_per_min +
            parts[2] * std.time.ms_per_s + ms,
        else => error.InvalidTimestamp,
    };
}

/// Append one payload line with markup removed.
fn appendPayload(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    line: []const u8,
) std.mem.Allocator.Error!void {
    var i: usize = 0;
    while (i < line.len) {
        switch (line[i]) {
            '<' => {
                // An inline tag or a karaoke timestamp. Neither survives onto a
                // plain character display; an unterminated one eats the rest.
                i = if (std.mem.indexOfScalarPos(u8, line, i, '>')) |close|
                    close + 1
                else
                    line.len;
            },
            '&' => {
                if (std.mem.indexOfScalarPos(u8, line, i, ';')) |semi| {
                    if (entity(line[i + 1 .. semi])) |replacement| {
                        try out.appendSlice(allocator, replacement);
                        i = semi + 1;
                        continue;
                    }
                }
                // Not a known escape, so it is a literal ampersand.
                try out.append(allocator, '&');
                i += 1;
            },
            else => |c| {
                try out.append(allocator, c);
                i += 1;
            },
        }
    }
}

/// The escapes WebVTT defines. The two direction marks have no glyph, so they
/// map to nothing rather than to a stray character.
fn entity(name: []const u8) ?[]const u8 {
    const table = .{
        .{ "amp", "&" },
        .{ "lt", "<" },
        .{ "gt", ">" },
        .{ "nbsp", " " },
        .{ "lrm", "" },
        .{ "rlm", "" },
    };
    inline for (table) |pair| {
        if (std.mem.eql(u8, name, pair[0])) return pair[1];
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parses a hand-written cue file" {
    const source =
        "WEBVTT Blade Runner\n" ++
        "\n" ++
        "NOTE\n" ++
        "Display is 20 columns; longer text is clipped.\n" ++
        "\n" ++
        "opening\n" ++
        "00:02:10.000 --> 00:02:25.000\n" ++
        "OPENING CRAWL\n" ++
        "\n" ++
        "01:47:30.500 --> 01:47:55.000 align:start\n" ++
        "TEARS IN RAIN\n";

    var list = try parse(testing.allocator, source);
    defer list.deinit();

    try testing.expectEqualStrings("Blade Runner", list.title);
    try testing.expectEqual(@as(usize, 2), list.cues.len);
    try testing.expectEqual(@as(i64, 130_000), list.cues[0].start_ms);
    try testing.expectEqual(@as(i64, 145_000), list.cues[0].end_ms);
    try testing.expectEqualStrings("OPENING CRAWL", list.cues[0].text);
    // Cue settings after the end timestamp must not corrupt it.
    try testing.expectEqual(@as(i64, 6_450_500), list.cues[1].start_ms);
    try testing.expectEqualStrings("TEARS IN RAIN", list.cues[1].text);
}

test "at covers the half-open interval and the gaps between cues" {
    const source =
        "WEBVTT\n\n" ++
        "00:00:10.000 --> 00:00:20.000\nFIRST\n\n" ++
        "00:00:30.000 --> 00:00:40.000\nSECOND\n";

    var list = try parse(testing.allocator, source);
    defer list.deinit();

    try testing.expectEqual(@as(?Cue, null), list.at(0));
    try testing.expectEqual(@as(?Cue, null), list.at(9_999));
    try testing.expectEqualStrings("FIRST", list.at(10_000).?.text);
    try testing.expectEqualStrings("FIRST", list.at(19_999).?.text);
    // End is exclusive, so the line clears exactly when the cue expires.
    try testing.expectEqual(@as(?Cue, null), list.at(20_000));
    try testing.expectEqualStrings("SECOND", list.at(35_000).?.text);
    try testing.expectEqual(@as(?Cue, null), list.at(40_000));
}

test "NOTE blocks and their contents never reach the display" {
    const source =
        "WEBVTT\n\n" ++
        "NOTE this looks like a cue but is not\n" ++
        "00:00:01.000 --> 00:00:02.000\n" ++
        "SHOULD NOT APPEAR\n" ++
        "\n" ++
        "00:00:05.000 --> 00:00:06.000\nREAL\n";

    var list = try parse(testing.allocator, source);
    defer list.deinit();

    try testing.expectEqual(@as(usize, 1), list.cues.len);
    try testing.expectEqualStrings("REAL", list.cues[0].text);
}

test "multi-line payloads flatten and markup is stripped" {
    const source =
        "WEBVTT\n\n" ++
        "00:00:01.000 --> 00:00:02.000\n" ++
        "<v Roy>MORE <b>HUMAN</b>\n" ++
        "THAN HUMAN &amp; PROUD\n";

    var list = try parse(testing.allocator, source);
    defer list.deinit();

    try testing.expectEqualStrings("MORE HUMAN THAN HUMAN & PROUD", list.cues[0].text);
}

test "MM:SS timestamps and SubRip comma fractions are accepted" {
    const source =
        "WEBVTT\n\n" ++
        "02:10.000 --> 02:25.000\nSHORT FORM\n\n" ++
        "00:03:00,250 --> 00:03:01,000\nCOMMA\n";

    var list = try parse(testing.allocator, source);
    defer list.deinit();

    try testing.expectEqual(@as(i64, 130_000), list.cues[0].start_ms);
    try testing.expectEqual(@as(i64, 180_250), list.cues[1].start_ms);
}

test "a malformed cue is skipped without losing the rest of the file" {
    const source =
        "WEBVTT\n\n" ++
        "not:a:time --> also:not\nBROKEN\n\n" ++
        "00:00:05.000 --> 00:00:06.000\nFINE\n";

    var list = try parse(testing.allocator, source);
    defer list.deinit();

    try testing.expectEqual(@as(usize, 1), list.cues.len);
    try testing.expectEqualStrings("FINE", list.cues[0].text);
}

test "out-of-order cues are sorted so at stays correct" {
    const source =
        "WEBVTT\n\n" ++
        "00:00:30.000 --> 00:00:40.000\nLATER\n\n" ++
        "00:00:10.000 --> 00:00:20.000\nEARLIER\n";

    var list = try parse(testing.allocator, source);
    defer list.deinit();

    try testing.expectEqualStrings("EARLIER", list.cues[0].text);
    try testing.expectEqualStrings("EARLIER", list.at(15_000).?.text);
    try testing.expectEqualStrings("LATER", list.at(35_000).?.text);
}

test "a leading asterisk marks a warning line that must not scroll" {
    const source =
        "WEBVTT\n\n" ++
        "00:00:01.000 --> 00:00:02.000\n" ++
        "*  LOUD PART COMING UP RIGHT NOW\n\n" ++
        "00:00:05.000 --> 00:00:06.000\n" ++
        "3m17 Charming The Pziiffelback\n\n" ++
        // Only a *leading* asterisk is a marker; one inside the text is text.
        "00:00:09.000 --> 00:00:10.000\n" ++
        "2m11 The Dragon *Book*\n";

    var list = try parse(testing.allocator, source);
    defer list.deinit();

    const warning = list.at(1_500).?;
    try testing.expect(!warning.scroll);
    // The marker is displayed, not consumed: it is what makes the line read as
    // a warning on the panel. Spacing after it is the author's to choose.
    try testing.expectEqualStrings("*  LOUD PART COMING UP RIGHT NOW", warning.text);

    const normal = list.at(5_500).?;
    try testing.expect(normal.scroll);
    try testing.expectEqualStrings("3m17 Charming The Pziiffelback", normal.text);

    const inner = list.at(9_500).?;
    try testing.expect(inner.scroll);
    try testing.expectEqualStrings("2m11 The Dragon *Book*", inner.text);
}

test "an asterisk on a multi-line payload still marks the whole cue" {
    const source =
        "WEBVTT\n\n" ++
        "00:00:01.000 --> 00:00:02.000\n" ++
        "*STOP\n" ++
        "THE FIGHT\n";

    var list = try parse(testing.allocator, source);
    defer list.deinit();

    const cue = list.at(1_500).?;
    try testing.expect(!cue.scroll);
    try testing.expectEqualStrings("*STOP THE FIGHT", cue.text);
}

test "a file without the signature is rejected" {
    try testing.expectError(error.NotWebVtt, parse(testing.allocator, "1\n00:00:01,000 --> 00:00:02,000\nSRT\n"));
    // `WEBVTTX` is not the signature; the keyword must stand alone.
    try testing.expectError(error.NotWebVtt, parse(testing.allocator, "WEBVTTX\n"));
}
