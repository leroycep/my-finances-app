const std = @import("std");

pub const Document = struct {};

pub const Event = struct {
    loc: u32,
    tag: enum {
        // Generic start/close; check the loc for more details
        other_start,
        other_close,
    },
};

pub fn parse(allocator: std.mem.Allocator, src: []const u8) ![]Event {
    std.debug.assert(src.len <= std.math.maxInt(u32));
    const State = enum {
        default,
    };

    const tokens = try tokenize(allocator, src);
    defer allocator.free(tokens);

    var events = std.ArrayList(Event).init(allocator);
    defer events.deinit();

    var state = State.default;
    var i: u32 = 0;
    while (i < src.len) {
        switch (state) {
            .default => switch (src[i]) {
                else => i += 1,
            },
        }
    }

    return events.toOwnedSlice();
}

pub const Token = struct {
    loc: Loc,
    tag: Tag,

    pub const Loc = struct {
        start: u32,
        end: u32,
    };

    pub const Tag = enum {
        eof,
        text,
        forward_slash,
        angle_start,
        angle_close,
    };

    pub fn fmtWithSrc(this: @This(), src: []const u8) FmtWithSrc {
        return FmtWithSrc{ .src = src, .token = this };
    }

    pub const FmtWithSrc = struct {
        src: []const u8,
        token: Token,

        pub fn format(
            this: @This(),
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            try writer.print("{s} \"{}\"", .{
                std.meta.tagName(this.token.tag),
                std.zig.fmtEscapes(this.src[this.token.loc.start..this.token.loc.end]),
            });
        }
    };
};

pub fn tokenize(allocator: std.mem.Allocator, src: []const u8) ![]Token {
    var tokens = std.ArrayList(Token).init(allocator);
    defer tokens.deinit();

    var pos: u32 = 0;
    while (true) {
        var token = try getToken(src, pos);
        try tokens.append(token);

        pos = token.loc.end;
        if (token.tag == .eof) {
            break;
        }
    }

    return tokens.toOwnedSlice();
}

pub fn getToken(src: []const u8, pos: u32) !Token {
    const State = enum {
        default,
        text,
    };

    var state = State.default;
    var token = Token{
        .tag = .eof,
        .loc = .{
            .start = pos,
            .end = undefined,
        },
    };

    var i = pos;
    while (i < src.len) {
        const c = src[i];
        switch (state) {
            .default => switch (c) {
                '<' => {
                    token.tag = .angle_start;
                    i += 1;
                    break;
                },
                '>' => {
                    token.tag = .angle_close;
                    i += 1;
                    break;
                },
                '/' => {
                    token.tag = .forward_slash;
                    i += 1;
                    break;
                },
                else => {
                    token.tag = .text;
                    state = .text;
                    i += 1;
                },
            },
            .text => switch (c) {
                '<', '/', '>' => break,
                else => i += 1,
            },
        }
    }

    token.loc.end = i;

    return token;
}
