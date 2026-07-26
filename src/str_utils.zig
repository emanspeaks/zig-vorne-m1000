const std = @import("std");
const protocol = @import("protocol.zig");
const DLE = protocol.DLE[0];

pub const maxchars = 20;
pub const maxbufsz = maxchars * 2; // double wide for special characters

pub fn clearVorneLineBuf(linebuf: *[maxbufsz]u8) !void {
    @memset(linebuf[0..maxchars], ' ');
    @memset(linebuf[maxchars..maxbufsz], 0);
}

/// The byte position where display-character `cidx` starts (or, if `cidx`
/// equals the total character count, one past the last character -- the
/// common "end of range" query).
///
/// A DLE-escaped glyph is two bytes for one displayed character, so this is
/// not simply `return cidx`: it has to walk `s` counting characters (not
/// bytes) up to `cidx`, then report the *byte* position reached.
pub fn idxChar2Str(s: []const u8, cidx: usize) !usize {
    var chars: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        // Checked before consuming this character's bytes, so the position
        // returned is where it *starts* -- for a DLE pair, the DLE byte
        // itself, not the code byte after it.
        if (chars == cidx) return i;
        i += if (s[i] == DLE and i + 1 < s.len) @as(usize, 2) else 1;
        chars += 1;
    }
    if (chars == cidx) return i;
    return error.InvalidIndex;
}

// pub fn strlen(s: [maxbufsz]u8) !usize {
//     // Find the actual length of the label (stop at first null byte)
//     return strlensz(s)[0];
// }

pub fn strlensz(s: []const u8) ![2]usize {
    // Find the actual length of the label (stop at first null byte)
    var i: usize = 0;
    var j: usize = 0;
    for (s) |c| {
        if (c == 0) break;
        j += 1; // bytes
        if (c == DLE) continue;
        i += 1; // char
    }
    return .{ i, j };
}

pub fn copyLeftJustify(dest: *[maxbufsz]u8, src: []const u8, maxlen: ?usize, offset: ?usize) !void {
    const charoffset = offset orelse 0;
    const maxcharlen = maxlen orelse maxchars - charoffset;
    const bufcharlen = @max(0, maxcharlen);

    const destlensz = strlensz(dest) catch unreachable;
    const srclensz = strlensz(src) catch unreachable;

    const copycharlen = @min(srclensz[0], bufcharlen);
    const destendidx = idxChar2Str(dest, charoffset + copycharlen) catch unreachable;

    const startidx = idxChar2Str(dest, charoffset) catch unreachable;
    // const endidx = startidx + srclensz[1];
    var srcendidx = srclensz[1];
    if (srclensz[0] > bufcharlen) {
        srcendidx = idxChar2Str(src, copycharlen) catch unreachable;
    }
    const endidx = startidx + srcendidx;

    const remchar = bufcharlen - copycharlen;
    const remendidx = endidx + remchar;

    if (copycharlen > 0) {
        // move contents of the rest of the line after the buffer in case the
        // incoming text is wider or narrower than the original replaced chars
        if (remendidx != destendidx) {
            const newendidx = remendidx + destlensz[1] - destendidx;
            @memmove(dest[remendidx..newendidx], dest[destendidx..destlensz[1]]);
            if (remendidx < destendidx) {
                @memset(dest[newendidx..maxbufsz], 0);
            }
        }
        @memcpy(dest[startidx..endidx], src[0..srcendidx]);
        if (remchar > 0) {
            @memset(dest[endidx..remendidx], ' ');
        }
        // const remstr = maxbufsz - remendidx;
        // if (remstr > 0) {
        //     @memset(dest[remendidx .. maxbufsz], 0);
        // }
    }
}

pub fn copyRightJustify(dest: *[maxbufsz]u8, src: []const u8, maxlen: ?usize, offset: ?usize) !void {
    const charoffset = offset orelse 0;
    const maxcharlen = maxlen orelse maxchars - charoffset;
    const bufcharlen = @max(0, maxcharlen);

    const destlensz = strlensz(dest) catch unreachable;
    const srclensz = strlensz(src) catch unreachable;

    const copycharlen = @min(srclensz[0], bufcharlen);
    const endcharidx = maxchars - charoffset;
    const startcharidx = endcharidx - copycharlen;

    const remchar = bufcharlen - copycharlen;
    const remstartcharidx = startcharidx - remchar;

    const remstartidx = idxChar2Str(dest, remstartcharidx) catch unreachable;
    const destendidx = idxChar2Str(dest, endcharidx) catch unreachable;

    const startidx = remstartidx + remchar;
    // const endidx = startidx + srclensz[1];
    var srcendidx = srclensz[1];
    if (srclensz[0] > bufcharlen) {
        srcendidx = idxChar2Str(src, copycharlen) catch unreachable;
    }
    const endidx = startidx + srcendidx;

    if (copycharlen > 0) {
        // move contents of the rest of the line after the buffer in case the
        // incoming text is wider or narrower than the original replaced chars
        if (endidx != destendidx) {
            const newendidx = endidx + destlensz[1] - destendidx;
            @memmove(dest[endidx..newendidx], dest[destendidx..destlensz[1]]);
            if (endidx < destendidx) {
                @memset(dest[newendidx..maxbufsz], 0);
            }
        }
        @memcpy(dest[startidx..endidx], src[0..srcendidx]);
        if (remchar > 0) {
            @memset(dest[remstartidx..startidx], ' ');
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "idxChar2Str finds the byte position of a character, not the character count" {
    // "\x10\x50" is one DLE-escaped display character (two bytes); "AB" is two
    // more (one byte each). A version of this function that returned the
    // character index unchanged would pass every case here that has no DLE
    // byte before the target and fail every one that does -- which is exactly
    // why the previous version's bug never showed up in ordinary ASCII text.
    const s = "\x10\x50AB";
    try testing.expectEqual(@as(usize, 0), try idxChar2Str(s, 0)); // the DLE pair itself
    try testing.expectEqual(@as(usize, 2), try idxChar2Str(s, 1)); // 'A', after the pair
    try testing.expectEqual(@as(usize, 3), try idxChar2Str(s, 2)); // 'B'
    try testing.expectEqual(@as(usize, 4), try idxChar2Str(s, 3)); // one past the end
    try testing.expectError(error.InvalidIndex, idxChar2Str(s, 4));
}

test "idxChar2Str matches the character index directly when there is no DLE byte" {
    const s = "hello";
    for (0..s.len + 1) |i| {
        try testing.expectEqual(i, try idxChar2Str(s, i));
    }
}

test "copyLeftJustify copies a DLE-escaped glyph without splitting the pair" {
    var dest: [maxbufsz]u8 = undefined;
    try clearVorneLineBuf(&dest);
    // Same glyph as bluray.PLAYCHAR: DLE + 'P' is one column, so "A\x10PB" is
    // three columns in four bytes -- padding to a full 20-column line is 17
    // more (space) bytes, for 21 total, not 20: a DLE pair makes byte count
    // and column count disagree, which is exactly the distinction this
    // function exists to get right.
    try copyLeftJustify(&dest, "A\x10PB", null, null);
    try testing.expectEqualSlices(u8, "A\x10PB" ++ (" " ** 17), dest[0..21]);
    try testing.expectEqual(@as(usize, 20), (try strlensz(dest[0..21]))[0]);
}
