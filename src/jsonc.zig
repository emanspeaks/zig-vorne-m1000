//! Reduce JSONC (JSON with comments and trailing commas) to plain JSON.
//!
//! `std.json` accepts neither, and the config files in this project are meant
//! to be hand-edited, where both matter: a comment explains what a knob does,
//! and a trailing comma stops a one-line edit from being a syntax error.
//!
//! String-aware, which the older copy of this logic inside `config.zig` is
//! not. `//` and `/*` inside a JSON string are ordinary characters -- a Windows
//! path, a URL, a cue payload -- and stripping them silently corrupts the value
//! rather than failing, so the damage shows up as a baffling parse error
//! somewhere else, or worse, as a config that parses to the wrong thing.

const std = @import("std");

/// Strip comments and trailing commas. Caller owns the returned list.
pub fn strip(allocator: std.mem.Allocator, src: []const u8) !std.ArrayList(u8) {
    var no_comments: std.ArrayList(u8) = .empty;
    defer no_comments.deinit(allocator);

    var i: usize = 0;
    var in_string = false;
    while (i < src.len) {
        const c = src[i];

        if (in_string) {
            try no_comments.append(allocator, c);
            // A backslash escape can hide a quote, so consume both together --
            // otherwise `"a\""` is read as ending one character early and the
            // rest of the file is parsed in the wrong mode.
            if (c == '\\' and i + 1 < src.len) {
                try no_comments.append(allocator, src[i + 1]);
                i += 2;
                continue;
            }
            if (c == '"') in_string = false;
            i += 1;
            continue;
        }

        if (c == '"') {
            in_string = true;
            try no_comments.append(allocator, c);
            i += 1;
            continue;
        }

        if (c == '/' and i + 1 < src.len) {
            if (src[i + 1] == '/') {
                i += 2;
                while (i < src.len and src[i] != '\n' and src[i] != '\r') i += 1;
                continue;
            }
            if (src[i + 1] == '*') {
                i += 2;
                while (i + 1 < src.len) {
                    if (src[i] == '*' and src[i + 1] == '/') {
                        i += 2;
                        break;
                    }
                    i += 1;
                } else {
                    // Unterminated block comment: everything left is comment.
                    i = src.len;
                }
                continue;
            }
        }

        try no_comments.append(allocator, c);
        i += 1;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const text = no_comments.items;
    i = 0;
    in_string = false;
    while (i < text.len) {
        const c = text[i];

        if (in_string) {
            try out.append(allocator, c);
            if (c == '\\' and i + 1 < text.len) {
                try out.append(allocator, text[i + 1]);
                i += 2;
                continue;
            }
            if (c == '"') in_string = false;
            i += 1;
            continue;
        }

        if (c == '"') {
            in_string = true;
            try out.append(allocator, c);
            i += 1;
            continue;
        }

        // A comma is trailing when the next non-whitespace character closes the
        // object or array it sits in.
        if (c == ',') {
            var j = i + 1;
            while (j < text.len and std.ascii.isWhitespace(text[j])) j += 1;
            if (j < text.len and (text[j] == '}' or text[j] == ']')) {
                i += 1;
                continue;
            }
        }

        try out.append(allocator, c);
        i += 1;
    }

    return out;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectStrip(expected: []const u8, src: []const u8) !void {
    var out = try strip(testing.allocator, src);
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings(expected, out.items);
}

test "strips line and block comments" {
    // Whitespace around a removed comment is left exactly as it was -- the
    // newline ending a line comment, and any space before it. JSON does not
    // care, and preserving it keeps byte offsets closer to the original, which
    // matters if a parse error is ever reported against a position.
    try expectStrip("{\"a\":1}\n", "{\"a\":1}// trailing\n");
    try expectStrip("\n{\"a\":1}", "// leading\n{\"a\":1}");
    try expectStrip("{\"a\":1}", "{/* inline */\"a\":1}");
    try expectStrip("{\n  \"a\":1 \n}", "{\n  \"a\":1 // why\n}");
}

test "leaves comment-like sequences inside strings alone" {
    // The whole reason this is string-aware. Stripping here would silently
    // rewrite the value rather than fail, which is far harder to diagnose.
    try expectStrip("{\"p\":\"http://x/y\"}", "{\"p\":\"http://x/y\"}");
    try expectStrip("{\"p\":\"a/*b*/c\"}", "{\"p\":\"a/*b*/c\"}");
    try expectStrip("{\"p\":\"// not a comment\"}", "{\"p\":\"// not a comment\"}");
}

test "an escaped quote does not end the string early" {
    try expectStrip("{\"p\":\"say \\\"//\\\" ok\"}", "{\"p\":\"say \\\"//\\\" ok\"}");
}

test "removes trailing commas before a close" {
    try expectStrip("{\"a\":1}", "{\"a\":1,}");
    try expectStrip("[1,2]", "[1,2,]");
    try expectStrip("{\"a\":[1,2]}", "{\"a\":[1,2,],}");
    // Whitespace and newlines between the comma and the close still count.
    try expectStrip("{\"a\":1\n}", "{\"a\":1,\n}");
}

test "keeps separating commas" {
    try expectStrip("{\"a\":1,\"b\":2}", "{\"a\":1,\"b\":2}");
    try expectStrip("{\"a\":\",\"}", "{\"a\":\",\"}");
}

test "the result of stripping a commented config actually parses" {
    const src =
        \\{
        \\  // which debug categories are on
        \\  "debug": {
        \\    "pll": true,   /* the phase lock */
        \\    "serial": false,
        \\  },
        \\}
    ;
    var out = try strip(testing.allocator, src);
    defer out.deinit(testing.allocator);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.items, .{});
    defer parsed.deinit();
    const debug = parsed.value.object.get("debug").?.object;
    try testing.expect(debug.get("pll").?.bool);
    try testing.expect(!debug.get("serial").?.bool);
}

test "unterminated block comment does not run off the end" {
    try expectStrip("{", "{/* never closed");
}
