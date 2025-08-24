const std = @import("std");

const maxbufsz = 20;

pub fn clearVorneLineBuf(linebuf: *[maxbufsz]u8) !void {
    linebuf.* = [_]u8{' '} ** maxbufsz;
}

pub fn strlen(s: []const u8) !usize {
    // Find the actual length of the label (stop at first null byte)
    return std.mem.indexOfScalar(u8, s, 0) orelse s.len;
}

pub fn copyLeftJustify(dest: *[maxbufsz]u8, src: []const u8, maxlen: ?usize, offset: ?usize) !void {
    const offset2 = offset orelse 0;
    const maxlen2 = maxlen orelse maxbufsz - offset2;
    const srclen = strlen(src) catch unreachable;
    const buflen = @max(0, maxlen2);
    const copylen = @min(srclen, buflen);
    const endidx = copylen + offset2;
    const rem = buflen - copylen;
    if (copylen > 0) {
        @memcpy(dest[offset2..endidx], src[0..copylen]);
        if (rem > 0) {
            @memset(dest[endidx .. endidx + rem], ' ');
        }
    }
}

pub fn copyRightJustify(dest: *[maxbufsz]u8, src: []const u8, maxlen: ?usize, offset: ?usize) !void {
    const offset2 = offset orelse 0;
    const maxlen2 = maxlen orelse maxbufsz - offset2;
    const srclen = strlen(src) catch unreachable;
    const buflen = @max(0, maxlen2);
    const copylen = @min(srclen, buflen);
    const endidx = maxbufsz - offset2;
    const startidx = endidx - copylen;
    const rem = buflen - copylen;
    if (copylen > 0) {
        @memcpy(dest[startidx..endidx], src[srclen - copylen .. srclen]);
        if (rem > 0) {
            @memset(dest[startidx - rem .. startidx], ' ');
        }
    }
}
