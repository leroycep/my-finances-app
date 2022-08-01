const std = @import("std");
const http = @import("apple_pie");
pub const io_mode = .evented;
const sqlite3 = @import("sqlite3");
const sqlite_utils = @import("./sqlite-utils.zig");
const date_util = @import("./date.zig");
const ofx_sgml = @import("./ofx_sgml.zig");
const multipart_form_data = @import("./multipart-form-data.zig");

const Transaction = sqlite_utils.Transaction;

const APP_NAME = "my-finances-app";
const DEFAULT_PORT = 56428;

const Context = struct {
    allocator: std.mem.Allocator,
    db: *sqlite3.SQLite3,
};

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const data_dir_path = try std.fs.getAppDataDir(gpa.allocator(), APP_NAME);
    defer gpa.allocator().free(data_dir_path);

    std.log.info("data dir = \"{}\"", .{std.zig.fmtEscapes(data_dir_path)});

    var data_dir = try std.fs.cwd().makeOpenPath(data_dir_path, .{});
    defer data_dir.close();

    const db_path_z = try std.fs.path.joinZ(gpa.allocator(), &.{ data_dir_path, "finances.db" });
    defer gpa.allocator().free(db_path_z);

    std.log.info("opening database = \"{}\"", .{std.zig.fmtEscapes(db_path_z)});
    try sqlite3.config(.{ .log = .{ .logFn = sqliteLogCallback, .userdata = null } });
    var db = try sqlite3.SQLite3.open(db_path_z);
    defer db.close() catch @panic("Couldn't close sqlite database");
    try setupSchema(gpa.allocator(), db);

    var ctx = Context{
        .allocator = gpa.allocator(),
        .db = db,
    };

    const builder = http.router.Builder(*Context);

    std.log.info("Serving on http://{s}:{}", .{ "127.0.0.1", DEFAULT_PORT });
    try http.listenAndServe(
        gpa.allocator(),
        try std.net.Address.parseIp("127.0.0.1", DEFAULT_PORT),
        &ctx,
        comptime http.router.Router(*Context, &.{
            builder.get("/", index),
            builder.get("/currencies", getCurrencies),
            builder.post("/ofx", importOFX),
            //builder.get("/accounts", getAccounts),
            //builder.post("/accounts", postAccount),
            //builder.get("/rules/payee", getPayeeRules),
            //builder.post("/rules/payee", postPayeeRule),
            //builder.get("/assertions/balance", getBalanceAssertions),
            //builder.get("/transactions", getTransactions),
            builder.get("/static/:filename", staticFiles(.{
                .@"style.css" = .{ .css = @embedFile("style.css") },
                .@"tachyons.min.css" = .{ .css = @embedFile("tachyons.min.css") },
                .@"htmx.min.js" = .{ .js = @embedFile("htmx.min.js") },
                .@"_hyperscript.min.js" = .{ .js = @embedFile("_hyperscript.min.js") },
            })),
        }),
    );
}

fn index(ctx: *Context, res: *http.Response, req: http.Request) !void {
    _ = ctx;
    _ = req;
    try res.headers.put("Content-Type", "text/html");
    try res.writer().writeAll(@embedFile("./index.html"));
}

fn getCurrencies(ctx: *Context, res: *http.Response, req: http.Request) !void {
    _ = req;

    var out = res.writer();

    try res.headers.put("Content-Type", "text/html");
    try writeHTMLHeader(out, "Currencies");

    try out.writeAll(
        \\<table>
        \\<thead>
        \\<tr><th class="align-end">Opened</th><th class="align-end">Name</th><th class="align-end">Divisor</th></tr>
        \\</thead>
        \\<tbody>
    );

    var stmt = (try ctx.db.prepare_v2("SELECT id, day_opened, name, divisor FROM currencies", null)) orelse return error.NoStatement;
    defer stmt.finalize() catch {};
    while ((try stmt.step()) != .Done) {
        const id = stmt.columnInt64(0);
        const date_opened = date_util.julianDayNumberToGregorianDate(@intCast(u64, stmt.columnInt64(1)));
        const name = stmt.columnText(2);
        const divisor = stmt.columnInt64(3);
        // TODO: Escape note text
        try out.print(
            \\<tr><input type="hidden" name="currencies-id" values="{}"/><td class="align-end">{}</td><td class="align-end">{s}</td><td class="align-end">{}</td></tr>
        , .{ id, date_opened.fmtISO(), name, divisor });
    }

    try out.writeAll(
        \\</tbody>
        \\</table>
        \\</body>
        \\</html>
    );
}

fn importOFX(ctx: *Context, res: *http.Response, req: http.Request) !void {
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();

    const headers = try req.headers(arena.allocator());
    var multipart_iter = try multipart_form_data.parse(headers.get("Content-Type"), req.body());

    const src = while (try multipart_iter.next()) |part| {
        const form_name = part.formName() orelse continue;
        if (std.mem.eql(u8, "file", std.mem.trim(u8, form_name, "\""))) {
            break part.body;
        }
    } else {
        return error.InvalidInput; // TODO: Error 40x when input is invalid
    };

    const ofx_events = try ofx_sgml.parse(arena.allocator(), src);

    try res.headers.put("Content-Type", "text/html");
    var out = res.writer();

    try writeHTMLHeader(out, "Import OFX");

    try out.writeAll(
        \\<pre>
    );
    var indent: usize = 0;
    for (ofx_events) |event| {
        if (event.isClose()) indent -|= 1;

        var i: usize = 0;
        while (i < indent) : (i += 1) {
            try out.writeAll("\t");
        }
        try out.print("{}<br>", .{event.fmtWithSrc(src)});

        if (event.isStart()) indent += 1;
    }

    try out.writeAll(
        \\</pre>
        \\</body>
        \\</html>
    );
}

fn setupSchema(allocator: std.mem.Allocator, db: *sqlite3.SQLite3) !void {
    var txn = try Transaction.begin(@src(), db);
    defer txn.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    try sqlite_utils.ensureSchema(allocator, db, @embedFile("./schema.sql"));

    try sqlite_utils.executeScript(db, @embedFile("./defaults.sql"));

    try txn.commit();
}

pub const Blob = union(enum) {
    html: []const u8,
    css: []const u8,
    js: []const u8,

    pub fn contentType(this: @This()) []const u8 {
        return switch (this) {
            .html => "text/html",
            .css => "text/css",
            .js => "text/javascript",
        };
    }

    pub fn data(this: @This()) []const u8 {
        return switch (this) {
            .html => |d| d,
            .css => |d| d,
            .js => |d| d,
        };
    }
};

/// Expects an struct where the field names are files, and the values are Blobs
const StaticFilesCaptures = struct { filename: []const u8 };
fn staticFiles(comptime static_files: anytype) fn (*Context, *http.Response, http.Request, StaticFilesCaptures) http.Response.Error!void {
    const Handler = struct {
        fn handle(_: *Context, res: *http.Response, req: http.Request, captures: StaticFilesCaptures) http.Response.Error!void {
            _ = req;

            inline for (std.meta.fields(@TypeOf(static_files))) |field| {
                if (std.mem.eql(u8, captures.filename, field.name)) {
                    const static_file: Blob = @field(static_files, field.name);
                    try res.headers.put("Content-Type", static_file.contentType());
                    try res.writer().writeAll(static_file.data());
                    return;
                }
            }

            return res.notFound();
        }
    };
    return Handler.handle;
}

fn writeHTMLHeader(out: anytype, page_title: []const u8) !void {
    try out.print(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\  <meta charset="utf-8">
        \\  <title>{s} - My Finances App</title>
        \\
        \\  <meta name="viewport" content="width=device-width, initial-scale=1">
        \\  <script src="/static/htmx.min.js"></script>
        \\  <script src="/static/_hyperscript.min.js"></script>
        \\  <link rel="stylesheet" type="text/css" href="/static/tachyons.min.css">
        \\  <link rel="stylesheet" type="text/css" href="/static/style.css">
        \\  <body>
    , .{page_title});
}

fn srcLineStr(comptime src: std.builtin.SourceLocation) *const [srcLineStrLen(src):0]u8 {
    return std.fmt.comptimePrint("{s}:{}", .{ src.file, src.line });
}

fn srcLineStrLen(comptime src: std.builtin.SourceLocation) usize {
    return src.file.len + std.math.log10(src.line) + 2;
}

fn sqliteLogCallback(userdata: *anyopaque, errcode: c_int, msg: ?[*:0]const u8) callconv(.C) void {
    _ = userdata;
    std.log.scoped(.sqlite3).err("{s}: {?s}", .{ sqlite3.errstr(errcode), msg });
}

// TODO:
extern fn sqlite3_last_insert_rowid(*sqlite3.SQLite3) i64;
