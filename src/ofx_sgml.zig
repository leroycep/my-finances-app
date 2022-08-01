const std = @import("std");

pub const Document = struct {};

pub const Event = union(enum) {
    flat_element: Loc,
    text: Loc,
    // Generic start/close; check the loc for more details
    start_other: Loc,
    close_other: Loc,

    bankid: Loc,
    acctid: Loc,
    accttype: Loc,

    start_stmttrn,
    close_stmttrn,
    trntype: Loc,
    dtposted: Loc,
    trnamt: Loc,
    fitid: Loc,
    name: Loc,
    memo: Loc,

    pub fn isStart(this: @This()) bool {
        return switch (this) {
            .start_other,
            .start_stmttrn,
            => true,
            else => false,
        };
    }

    pub fn isClose(this: @This()) bool {
        return switch (this) {
            .close_other,
            .close_stmttrn,
            => true,
            else => false,
        };
    }

    pub fn getClose(this: @This()) ?@This() {
        return switch (this) {
            .start_stmttrn => return .close_stmttrn,
            .start_other => |loc| return @This(){ .close_other = loc },
            else => return null,
        };
    }

    pub fn fmtWithSrc(this: @This(), src: []const u8) FmtWithSrc {
        return FmtWithSrc{ .src = src, .event = this };
    }

    pub const FmtWithSrc = struct {
        src: []const u8,
        event: Event,

        pub fn format(
            this: @This(),
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            switch (this.event) {
                .start_stmttrn, .close_stmttrn => try writer.print("{s}", .{std.meta.tagName(this.event)}),

                .bankid,
                .acctid,
                .accttype,
                .trntype,
                .dtposted,
                .trnamt,
                .fitid,
                .name,
                .memo,
                .text,
                .start_other,
                .close_other,
                .flat_element,
                => |loc| try writer.print("{s} \"{}\"", .{
                    std.meta.tagName(this.event),
                    std.zig.fmtEscapes(loc.text(this.src)),
                }),
            }
        }
    };
};

pub fn parse(allocator: std.mem.Allocator, src: []const u8) ![]Event {
    std.debug.assert(src.len <= std.math.maxInt(u32));

    const tokens = try tokenize(allocator, src);
    defer allocator.free(tokens);

    var events = std.ArrayList(Event).init(allocator);
    defer events.deinit();

    var cursor = Cursor{ .tokens = tokens, .index = 0 };

    // Skip text until we get to the first `<`
    while (cursor.eat(.text) catch null) |_| {}

    while (true) {
        if (cursor.eat(.eof)) |_| {
            break;
        } else |_| try parseContainerElement(src, &cursor, &events);
    }

    return events.toOwnedSlice();
}

const CONTAINER_ELEMENTS = [_][]const u8{
    "OFX",
    "SIGNONMSGSRSV1",
    "SONRS",
    "STATUS",
    "STMTTRNRS",
    "STMTTRN",
    "FI",
    "BANKACCTFROM",
    "BANKTRANLIST",
    "LEDGERBAL",
    "AVAILBAL",
    "STMTRS",
    "BANKMSGSRSV1",
};

fn parseContainerElement(src: []const u8, cursor: *Cursor, events: *std.ArrayList(Event)) anyerror!void {
    const start = cursor.*;
    const events_start_len = events.items.len;
    errdefer {
        cursor.* = start;
        events.shrinkRetainingCapacity(events_start_len);
    }

    const element_start_event = try parseElementStart(src, cursor, events);

    if (events.items[element_start_event] == .start_other) {
        const element_name = events.items[element_start_event].start_other.text(src);

        for (CONTAINER_ELEMENTS) |container_name| {
            if (std.mem.eql(u8, element_name, container_name)) {
                break;
            }
        } else return error.NotAContainerElement;
    }

    while (cursor.peek()) |token| {
        switch (token.tag) {
            .eof => break,

            .text, .forward_slash => {
                try events.append(.{ .text = token.loc });
                _ = cursor.next();
            },
            .angle_start => {
                const before_parse_end = cursor.*;
                const before_parse_end_events_len = events.items.len;
                errdefer {
                    cursor.* = before_parse_end;
                    events.shrinkRetainingCapacity(before_parse_end_events_len);
                }

                if (parseElementEnd(src, cursor, events)) |element_end_event| {
                    const start_element = events.items[element_start_event];
                    const close_element = events.items[element_end_event];
                    const is_match = switch (start_element) {
                        .start_stmttrn => close_element == .close_stmttrn,
                        .start_other => |loc| close_element == .close_other and std.mem.eql(u8, loc.text(src), close_element.close_other.text(src)),
                        else => false,
                    };
                    if (!is_match) {
                        std.debug.print("{s}:{} element doesn't match ({} != {})\n", .{ @src().file, @src().line, start_element, close_element });
                        try events.append(events.items[element_end_event]);
                        events.items[element_end_event] = start_element.getClose().?;
                    }
                    break;
                } else |_| if (parseContainerElement(src, cursor, events)) {
                    //
                } else |_| if (parsePropertyElement(src, cursor, events)) |_| {
                    //
                } else |_| if (parseFlatElement(src, cursor, events)) {
                    //
                } else |e| {
                    return e;
                }
            },
            .angle_close => return error.InvalidSyntax,
        }
    }
}

fn parsePropertyElement(src: []const u8, cursor: *Cursor, events: *std.ArrayList(Event)) anyerror!u32 {
    const start = cursor.*;
    const events_start_len = events.items.len;
    errdefer {
        cursor.* = start;
        events.shrinkRetainingCapacity(events_start_len);
    }
    _ = src;

    _ = try cursor.eat(.angle_start);
    const element_name_token_idx = try cursor.eat(.text);
    _ = try cursor.eat(.angle_close);
    const value_loc = try mergeText(src, cursor, events);

    const element_name = cursor.tokens[element_name_token_idx].loc.text(src);
    const event_index = events.items.len;
    if (std.mem.eql(u8, element_name, "TRNTYPE")) {
        try events.append(.{ .trntype = value_loc });
    } else if (std.mem.eql(u8, element_name, "DTPOSTED")) {
        try events.append(.{ .dtposted = value_loc });
    } else if (std.mem.eql(u8, element_name, "TRNAMT")) {
        try events.append(.{ .trnamt = value_loc });
    } else if (std.mem.eql(u8, element_name, "FITID")) {
        try events.append(.{ .fitid = value_loc });
    } else if (std.mem.eql(u8, element_name, "NAME")) {
        try events.append(.{ .name = value_loc });
    } else if (std.mem.eql(u8, element_name, "MEMO")) {
        try events.append(.{ .memo = value_loc });
    } else if (std.mem.eql(u8, element_name, "BANKID")) {
        try events.append(.{ .bankid = value_loc });
    } else if (std.mem.eql(u8, element_name, "ACCTID")) {
        try events.append(.{ .acctid = value_loc });
    } else if (std.mem.eql(u8, element_name, "ACCTTYPE")) {
        try events.append(.{ .accttype = value_loc });
    } else {
        return error.UnrecognizedPropertyName;
    }
    return @intCast(u32, event_index);
}

fn mergeText(src: []const u8, cursor: *Cursor, events: *std.ArrayList(Event)) anyerror!Loc {
    const start = cursor.*;
    const events_start_len = events.items.len;
    errdefer {
        cursor.* = start;
        events.shrinkRetainingCapacity(events_start_len);
    }
    _ = src;

    const first_tok_idx = cursor.eat(.text) catch cursor.eat(.forward_slash) catch |e| return e;
    var loc = cursor.tokens[first_tok_idx].loc;
    while (cursor.peek()) |tok| {
        switch (tok.tag) {
            .text, .forward_slash => {
                _ = cursor.next();
                loc.end = tok.loc.end;
            },
            else => break,
        }
    }

    return loc;
}

fn parseFlatElement(src: []const u8, cursor: *Cursor, events: *std.ArrayList(Event)) anyerror!void {
    const start = cursor.*;
    const events_start_len = events.items.len;
    errdefer {
        cursor.* = start;
        events.shrinkRetainingCapacity(events_start_len);
    }
    _ = src;

    _ = try cursor.eat(.angle_start);
    const element_name_token_idx = try cursor.eat(.text);
    _ = try cursor.eat(.angle_close);

    try events.append(.{ .flat_element = cursor.tokens[element_name_token_idx].loc });

    while (cursor.peek()) |token| {
        switch (token.tag) {
            .eof, .angle_start => break,

            .text, .forward_slash => {
                try events.append(.{ .text = token.loc });
                _ = cursor.next();
            },

            .angle_close => return error.InvalidSyntax,
        }
    }
}

fn parseElementStart(src: []const u8, cursor: *Cursor, events: *std.ArrayList(Event)) !u32 {
    const start = cursor.*;
    const events_start_len = events.items.len;
    errdefer {
        cursor.* = start;
        events.shrinkRetainingCapacity(events_start_len);
    }
    _ = src;

    _ = try cursor.eat(.angle_start);
    const element_name_token_idx = try cursor.eat(.text);
    _ = try cursor.eat(.angle_close);

    const event_index = events.items.len;
    const element_name = cursor.tokens[element_name_token_idx].text(src);
    if (std.mem.eql(u8, element_name, "STMTTRN")) {
        try events.append(.start_stmttrn);
        //} else if (std.mem.eql(u8, element_name, "STMTTRN")) {
        //    try events.append(.{ .start_other = cursor.tokens[element_name_token_idx].loc });
    } else {
        try events.append(.{ .start_other = cursor.tokens[element_name_token_idx].loc });
    }

    return @intCast(u32, event_index);
}

fn parseElementEnd(src: []const u8, cursor: *Cursor, events: *std.ArrayList(Event)) !u32 {
    const start = cursor.*;
    const events_start_len = events.items.len;
    errdefer {
        cursor.* = start;
        events.shrinkRetainingCapacity(events_start_len);
    }
    _ = src;

    _ = try cursor.eat(.angle_start);
    _ = try cursor.eat(.forward_slash);
    const element_name_token_idx = try cursor.eat(.text);
    _ = try cursor.eat(.angle_close);

    const event_index = events.items.len;
    const element_name = cursor.tokens[element_name_token_idx].text(src);
    if (std.mem.eql(u8, element_name, "STMTTRN")) {
        try events.append(.close_stmttrn);
        //} else if (std.mem.eql(u8, element_name, "STMTTRN")) {
        //    try events.append(.{ .start_other = cursor.tokens[element_name_token_idx].loc });
    } else {
        try events.append(.{ .close_other = cursor.tokens[element_name_token_idx].loc });

        for (CONTAINER_ELEMENTS) |container_name| {
            if (std.mem.eql(u8, element_name, container_name)) {
                break;
            }
        } else {
            std.debug.print("Element name {s} not in list of containers!\n", .{element_name});
        }
    }

    return @intCast(u32, event_index);
}

const Cursor = struct {
    tokens: []Token,
    index: usize,

    pub fn peek(this: *@This()) ?Token {
        if (this.index >= this.tokens.len) return null;
        return this.tokens[this.index];
    }

    pub fn next(this: *@This()) ?Token {
        if (this.index >= this.tokens.len) return null;
        defer this.index += 1;
        return this.tokens[this.index];
    }

    pub fn eat(this: *@This(), expected_tag: Token.Tag) !u32 {
        if (this.index >= this.tokens.len) return error.UnexpectedEOF;
        if (this.tokens[this.index].tag == expected_tag) {
            defer this.index += 1;
            return @intCast(u32, this.index);
        }
        return error.UnexpectedToken;
    }
};

pub const Loc = struct {
    start: u32,
    end: u32,

    pub fn text(this: @This(), src: []const u8) []const u8 {
        return src[this.start..this.end];
    }
};

pub const Token = struct {
    loc: Loc,
    tag: Tag,

    pub const Tag = enum {
        eof,
        text,
        forward_slash,
        angle_start,
        angle_close,
    };

    pub fn text(this: @This(), src: []const u8) []const u8 {
        return this.loc.text(src);
    }

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
                std.zig.fmtEscapes(this.token.text(this.src)),
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
                '\r', '\n' => {
                    i += 1;
                    token.loc.start = i;
                },
                else => {
                    token.tag = .text;
                    state = .text;
                    i += 1;
                },
            },
            .text => switch (c) {
                '<', '/', '>', '\r', '\n' => break,
                else => i += 1,
            },
        }
    }

    token.loc.end = i;

    return token;
}
