//! The Vorne M1000's own character repertoire, and conversion to and from it.
//!
//! The panel is not a UTF-8 device. It has a fixed CP437-like set of glyphs,
//! described below in the decode direction (byte -> what it looks like). The
//! tables are also walked backwards by `encodeUtf8`, so text written with the
//! obvious character -- a track name like "Jonsi" spelled with an o-acute --
//! reaches the panel as the right glyph instead of two bytes of mojibake.
//!
//! Deliberately free of dependencies so it can be used by the cue parser
//! without dragging in the serial layer.

const std = @import("std");

/// Escape byte. A DLE followed by `0x40 + index` selects `control_chars[index]`,
/// which is how the graphic characters below the space are reached without
/// sending a raw control byte down the wire.
pub const DLE: u8 = 0x10;

// Control character lookup table for characters 0x00-0x1F and 0x7F
pub const control_chars = [_][]const u8{
    "<NUL>", // x00 - @
    "<SOH>", //"☺︎",  // x01 - A
    "☻", //"<STX>",  // x02 - B
    "♥︎", //"<ETX>",  // x03 - C
    "<EOT>", //"♦︎",  // x04 - D
    "♣︎", //"<ENQ>",  // x05 - E
    "♠︎", //"<ACK>",  // x06 - F
    "•", //"<BEL>",  // x07 - G  (rendered as small square bullet)
    "<BS>", //"◘",   // x08 - H
    "<HT>", //"○",   // x09 - I
    "<LF>", //"◙",   // x0a - J
    "<VT>", //"♂︎",   // x0b - K
    "<FF>", //"♀︎",   // x0c - L
    "<CR>", //"♪",   // x0d - M
    "♫", //"<SO>",   // x0e - N
    "☼", //"<SI>",   // x0f - O
    "►", //"<DLE>",  // x10 - P
    "◄", //"<DC1>",  // x11 - Q
    "↕︎", //"<DC2>",  // x12 - R
    "‼︎", //"<DC3>",  // x13 - S
    "¶", //"<DC4>",  // x14 - T
    "§", //"<NAK>",  // x15 - U
    "▬", //"<SYN>",  // x16 - V
    "↨", //"<ETB>",  // x17 - W
    "↑", //"<CAN>",  // x18 - X
    "↓", //"<EM>",   // x19 - Y
    "→", //"<SUB>",  // x1a - Z
    "<ESC>", //"←",  // x1b - [
    "∟", //"<FS>",   // x1c - \
    "↔︎", //"<GS>",   // x1d - ]
    "▲", //"<RS>",   // x1e - ^
    "▼", //"<US>",   // x1f - _
    "⌂", //"<DEL>",  // x7f - `
};

// Extended character lookup table for characters 0x80-0xFF (CP437/DOS)
pub const extended_chars = [_][]const u8{
    "Ç", // x80
    "ü", // x81
    "é", // x82
    "â", // x83
    "ä", // x84
    "à", // x85
    "å", // x86
    "ç", // x87
    "ê", // x88
    "ë", // x89
    "è", // x8a
    "ï", // x8b
    "î", // x8c
    "ì", // x8d
    "Ä", // x8e
    "Å", // x8f
    "É", // x90
    "æ", // x91
    "Æ", // x92
    "ô", // x93
    "ö", // x94
    "ò", // x95
    "û", // x96
    "ù", // x97
    "ÿ", // x98
    "Ö", // x99
    "Ü", // x9a
    "¢", // x9b
    "£", // x9c
    "¥", // x9d
    "<Pt>", // x9e
    "ƒ", // x9f
    "á", // xa0
    "í", // xa1
    "ó", // xa2
    "ú", // xa3
    "ñ", // xa4
    "Ñ", // xa5
    "a", // xa6
    "o", // xa7
    "¿", // xa8
    "⌐", // xa9
    "¬", // xaa
    "½", // xab
    "¼", // xac
    "¡", // xad
    "«", // xae
    "»", // xaf
    "░", // xb0
    "▒", // xb1
    "▓", // xb2
    "│", // xb3
    "┤", // xb4
    "╡", // xb5
    "╢", // xb6
    "╖", // xb7
    "╕", // xb8
    "╣", // xb9
    "║", // xba
    "╗", // xbb
    "╝", // xbc
    "╜", // xbd
    "╛", // xbe
    "┐", // xbf
    "└", // xc0
    "┴", // xc1
    "┬", // xc2
    "├", // xc3
    "─", // xc4
    "┼", // xc5
    "╞", // xc6
    "╟", // xc7
    "╚", // xc8
    "╔", // xc9
    "╩", // xca
    "╦", // xcb
    "╠", // xcc
    "═", // xcd
    "╬", // xce
    "╧", // xcf
    "╨", // xd0
    "╤", // xd1
    "╥", // xd2
    "╙", // xd3
    "╘", // xd4
    "╒", // xd5
    "╓", // xd6
    "╫", // xd7
    "╪", // xd8
    "┘", // xd9
    "┌", // xda
    "█", // xdb
    "▄", // xdc
    "▌", // xdd
    "▐", // xde
    "▀", // xdf
    "α", // xe0
    "ß", // xe1
    "Γ", // xe2
    "π", // xe3
    "Σ", // xe4
    "σ", // xe5
    "µ", // xe6
    "τ", // xe7
    "Φ", // xe8
    "Θ", // xe9
    "Ω", // xea
    "δ", // xeb
    "∞", // xec
    "φ", // xed
    "ε", // xee
    "∩", // xef
    "≡", // xf0
    "±", // xf1
    "≥", // xf2
    "≤", // xf3
    "⌠", // xf4
    "⌡", // xf5
    "÷", // xf6
    "≈", // xf7
    "°", // xf8
    "∙", // xf9
    "·", // xfa
    "√", // xfb
    "ⁿ", // xfc
    "²", // xfd
    "■", // xfe
    "�", // xff
};

// ---------------------------------------------------------------------------
// Encoding: UTF-8 in, panel bytes out
// ---------------------------------------------------------------------------

/// Table entries that describe a byte rather than name a glyph, so they must
/// never be matched when going the other way. `<NUL>`, `<ESC>` and friends are
/// placeholders for unprintable codes, and U+FFFD is the replacement character.
fn isPlaceholder(entry: []const u8) bool {
    return entry.len == 0 or entry[0] == '<' or std.mem.eql(u8, entry, "\u{FFFD}");
}

/// Text-presentation variation selector. Several table entries carry one, so a
/// plain heart or arrow typed into a cue file would not match the entry as
/// written; compare against the base character as well.
const vs15 = "\u{FE0E}";

fn entryMatches(entry: []const u8, utf8: []const u8) bool {
    if (std.mem.eql(u8, entry, utf8)) return true;
    if (std.mem.endsWith(u8, entry, vs15)) {
        return std.mem.eql(u8, entry[0 .. entry.len - vs15.len], utf8);
    }
    return false;
}

/// Characters with no glyph on the panel but an obvious ASCII stand-in. Almost
/// all of these arrive by pasting a track listing out of a web page.
const ascii_folds = [_]struct { u21, []const u8 }{
    .{ 0x2018, "'" }, // left single quote
    .{ 0x2019, "'" }, // right single quote / apostrophe
    .{ 0x201A, "'" },
    .{ 0x201C, "\"" }, // left double quote
    .{ 0x201D, "\"" }, // right double quote
    .{ 0x2013, "-" }, // en dash
    .{ 0x2014, "-" }, // em dash
    .{ 0x2212, "-" }, // minus sign
    .{ 0x2026, "..." }, // ellipsis
    .{ 0x00A0, " " }, // no-break space
    .{ 0x2009, " " }, // thin space
    .{ 0x200B, "" }, // zero-width space
    .{ 0xFEFF, "" }, // byte-order mark
};

/// Substituted for a character with no glyph and no sensible fold, so that a
/// stray character costs one column instead of corrupting the whole line.
pub const unmappable = '?';

/// Encode one code point into the panel's character set, appending to `out`.
///
/// Returns false if the code point has no representation and `unmappable` was
/// written instead, which callers may want to report.
pub fn encodeCodepoint(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    cp: u21,
) std.mem.Allocator.Error!bool {
    // Plain ASCII is already the panel's own encoding.
    if (cp < 0x80) {
        try out.append(allocator, @intCast(cp));
        return true;
    }

    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &buf) catch {
        try out.append(allocator, unmappable);
        return false;
    };
    const utf8 = buf[0..len];

    // The high half of the panel's set: accented Latin, Greek, box drawing.
    for (extended_chars, 0..) |entry, i| {
        if (isPlaceholder(entry)) continue;
        if (entryMatches(entry, utf8)) {
            try out.append(allocator, @intCast(0x80 + i));
            return true;
        }
    }

    // The graphic characters below the space, reached via a DLE escape rather
    // than by sending the raw control byte.
    for (control_chars, 0..) |entry, i| {
        if (isPlaceholder(entry)) continue;
        if (i >= 0x20) break; // the last entry is DEL, not a code below space
        if (entryMatches(entry, utf8)) {
            try out.append(allocator, DLE);
            try out.append(allocator, @intCast(0x40 + i));
            return true;
        }
    }

    for (ascii_folds) |fold| {
        if (fold[0] == cp) {
            try out.appendSlice(allocator, fold[1]);
            return true;
        }
    }

    try out.append(allocator, unmappable);
    return false;
}

/// Encode a UTF-8 string into the panel's character set.
///
/// Invalid UTF-8 is passed through byte by byte rather than rejected: cue files
/// are hand-edited, and a single bad byte should cost one character, not the
/// whole line.
pub fn encodeUtf8(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
) std.mem.Allocator.Error!void {
    var i: usize = 0;
    while (i < text.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            try out.append(allocator, unmappable);
            i += 1;
            continue;
        };
        if (i + seq_len > text.len) {
            try out.append(allocator, unmappable);
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(text[i .. i + seq_len]) catch {
            try out.append(allocator, unmappable);
            i += 1;
            continue;
        };
        _ = try encodeCodepoint(allocator, out, cp);
        i += seq_len;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn encode(text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    try encodeUtf8(testing.allocator, &out, text);
    return out.toOwnedSlice(testing.allocator);
}

test "ASCII passes through untouched" {
    const got = try encode("3m25 Romantic Flight");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("3m25 Romantic Flight", got);
}

test "accented Latin maps to the panel's own glyph" {
    // The case that prompted this: a track credited to Jonsi, spelled with an
    // o-acute, previously reached the panel as two bytes of mojibake.
    const got = try encode("J\u{00F3}nsi: Sticks & Stones");
    defer testing.allocator.free(got);

    // One byte per column now, and that byte is CP437's o-acute.
    try testing.expectEqual(@as(usize, 22), got.len);
    try testing.expectEqual(@as(u8, 0xA2), got[1]);
    try testing.expectEqualStrings("J", got[0..1]);
    try testing.expectEqualStrings("nsi: Sticks & Stones", got[2..]);
}

test "a spread of accented characters all resolve" {
    const cases = [_]struct { []const u8, u8 }{
        .{ "\u{00E9}", 0x82 }, // e-acute
        .{ "\u{00FC}", 0x81 }, // u-diaeresis
        .{ "\u{00F1}", 0xA4 }, // n-tilde
        .{ "\u{00C5}", 0x8F }, // A-ring
        .{ "\u{00E6}", 0x91 }, // ae
        .{ "\u{00BF}", 0xA8 }, // inverted question mark
        .{ "\u{00B0}", 0xF8 }, // degree
        .{ "\u{00B1}", 0xF1 }, // plus-minus
    };
    for (cases) |case| {
        const got = try encode(case[0]);
        defer testing.allocator.free(got);
        try testing.expectEqual(@as(usize, 1), got.len);
        try testing.expectEqual(case[1], got[0]);
    }
}

test "typographic punctuation folds to ASCII rather than becoming noise" {
    const got = try encode("Don\u{2019}t \u{201C}Stop\u{201D} \u{2013} Now\u{2026}");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("Don't \"Stop\" - Now...", got);
}

test "graphic characters below the space use a DLE escape" {
    // These cannot be sent as raw control bytes, so they take two bytes on the
    // wire but still occupy one column, which is what `str_utils` counts.
    const got = try encode("\u{25BA}"); // right-pointing triangle
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqual(DLE, got[0]);
    // Exactly what `bluray.PLAYCHAR` hard-codes for the same glyph.
    try testing.expectEqualStrings("\x10P", got);
}

test "a table entry written with a variation selector still matches the plain character" {
    // Some entries are spelled with U+FE0E appended. Nobody types that, so
    // matching only the exact entry would leave those glyphs unreachable.
    const got = try encode("\u{2665}"); // heart, entry is "heart + U+FE0E"
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqual(DLE, got[0]);
    try testing.expectEqual(@as(u8, 0x40 + 0x03), got[1]);
}

test "a placeholder in the middle of the table does not shift later glyphs" {
    // `<Pt>` sits at 0x9E. An off-by-one in the reverse walk would show up as
    // every glyph after it resolving to the wrong byte.
    const got = try encode("\u{0192}"); // florin, the entry right after <Pt>
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(@as(u8, 0x9F), got[0]);
}

test "an unmappable character costs one column, not the line" {
    const got = try encode("A\u{4E2D}B"); // a CJK ideograph
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("A?B", got);
}

test "placeholder table entries are never matched backwards" {
    // `control_chars` spells unprintable codes as "<NUL>", "<ESC>" and so on.
    // Matching those would turn a literal "<" into a control byte.
    const got = try encode("<ESC> <NUL>");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("<ESC> <NUL>", got);
}

test "invalid UTF-8 degrades to one replacement per bad byte" {
    const got = try encode("ok\xFFhere");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("ok?here", got);
}
