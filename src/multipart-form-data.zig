const std = @import("std");

pub fn parse(content_type: ?[]const u8, body: []const u8) !MultipartFormDataIter {
    var entry_iter = std.mem.split(u8, content_type.?, ";");
    const mime_type = entry_iter.first();
    if (!std.mem.eql(u8, "multipart/form-data", mime_type)) {
        return error.InvalidContentType; // Expected multipart/form-data;
    }

    const boundary = while (entry_iter.next()) |entry| {
        var kv_iter = std.mem.split(u8, std.mem.trim(u8, entry, " "), "=");
        const key = kv_iter.first();
        const val = kv_iter.rest();

        if (std.mem.eql(u8, "boundary", key)) {
            break val;
        }
    } else {
        return error.InvalidContentType; // TODO: Allow multipart forms without boundary parameter
    };

    if (std.mem.startsWith(u8, boundary, "\"")) {
        return error.Unimplemented; // Boundaries enclosed in strings are not implemented
    }

    std.debug.assert(boundary.len <= 70);

    var boundary_buf: [74]u8 = undefined;
    std.mem.copy(u8, boundary_buf[0..4], "\r\n--");
    std.mem.copy(u8, boundary_buf[4..], boundary);
    const boundary_len = 4 + boundary.len;

    // First boundary, don't require the CRLF
    const first_boundary = std.mem.indexOf(u8, body, boundary_buf[0..boundary_len][2..]);

    return MultipartFormDataIter{
        .body = body,
        .index = if (first_boundary) |f| f + boundary_len - 2 else null,
        .boundary_buf = boundary_buf,
        .boundary_len = boundary_len,
    };
}

pub const MultipartFormDataIter = struct {
    body: []const u8,
    index: ?usize,
    boundary_buf: [74]u8,
    boundary_len: usize,

    pub const Part = struct {
        headers: []const u8,
        body: []const u8,

        pub fn formName(this: @This()) ?[]const u8 {
            var header_iter = std.mem.split(u8, this.headers, "\r\n");
            while (header_iter.next()) |header_line| {
                if (!std.mem.startsWith(u8, header_line, "Content-Disposition:")) continue;
                var entry_iter = std.mem.split(u8, header_line, ";");

                while (entry_iter.next()) |entry| {
                    var kv_iter = std.mem.split(u8, std.mem.trim(u8, entry, " "), "=");
                    const key = kv_iter.first();
                    const val = kv_iter.rest();

                    if (std.mem.eql(u8, "name", key)) {
                        return val;
                    }
                }
            }

            return null;
        }
    };

    pub fn next(this: *@This()) !?Part {
        const start = this.index orelse return null;
        if (std.mem.startsWith(u8, this.body[start..], "--")) {
            this.index = null;
            return null;
        }
        const end = std.mem.indexOfPos(u8, this.body, start, this.boundary()) orelse return error.UnexpectedEOF;
        this.index = end + this.boundary_len;

        const part_buffer = this.body[start..end];

        const headers_end = std.mem.indexOf(u8, part_buffer, "\r\n\r\n") orelse return error.InvalidFormat;
        const body_start = headers_end + 4;

        return Part{
            .headers = part_buffer[0..headers_end],
            .body = part_buffer[body_start..],
        };
    }

    fn boundary(this: *const @This()) []const u8 {
        return this.boundary_buf[0..this.boundary_len];
    }
};
