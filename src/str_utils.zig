const std = @import("std");
const protocol = @import("protocol.zig");
const DLE = protocol.DLE[0];

pub const maxchars = 20;
pub const maxbufsz = maxchars * 2; // double wide for special characters

pub fn clearVorneLineBuf(linebuf: *[maxbufsz]u8) !void {
    @memset(linebuf[0..maxchars], ' ');
    @memset(linebuf[maxchars..maxbufsz], 0);
}

pub fn idxChar2Str(s: []const u8, cidx: usize) !usize {
    var i: usize = 0;
    for (s) |c| {
        if (c == DLE) continue;
        if (i == cidx) return i;
        i += 1;
    }
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
        j += 1;
        if (c == DLE) continue;
        i += 1;
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
    const endidx = startidx + srclensz[1];

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
        @memcpy(dest[startidx..endidx], src[0..srclensz[1]]);
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
    const endidx = startidx + srclensz[1];

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
        @memcpy(dest[startidx..endidx], src[0..srclensz[1]]);
        if (remchar > 0) {
            @memset(dest[remstartidx..startidx], ' ');
        }
    }
}
