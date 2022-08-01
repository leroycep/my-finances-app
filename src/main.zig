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

    @setEvalBranchQuota(10000);
    std.log.info("Serving on http://{s}:{}", .{ "127.0.0.1", DEFAULT_PORT });
    try http.listenAndServe(
        gpa.allocator(),
        try std.net.Address.parseIp("127.0.0.1", DEFAULT_PORT),
        &ctx,
        comptime http.router.Router(*Context, &.{
            builder.get("/", index),
            builder.get("/currencies", getCurrencies),
            builder.get("/ofx/transactions", getOFXTransactions),
            builder.get("/ofx/ledger_balances", getOFXLedgerBalances),
            builder.get("/ofx/accounts", getOFXAccounts),
            builder.get("/ofx/accounts/:account_id", getOFXAccount),
            builder.put("/ofx/accounts/:account_id", putOFXAccount),
            builder.post("/ofx", postOFX),
            builder.post("/ofx/debug", debugParseOFX),
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

fn getOFXAccounts(ctx: *Context, res: *http.Response, req: http.Request) !void {
    _ = req;

    var out = res.writer();

    try res.headers.put("Content-Type", "text/html");
    try writeHTMLHeader(out, "Accounts");

    try out.writeAll(
        \\<table>
        \\<thead>
        \\<tr><th class="align-start">OFX Account Hash</th><th class="align-start">Account</th></tr>
        \\</thead>
        \\<tbody>
    );

    var stmt = (try ctx.db.prepare_v2(
        \\SELECT ofx_accounts.id, ofx_accounts.hash, ofx_account_names.name
        \\FROM ofx_accounts
        \\LEFT JOIN ofx_account_names ON ofx_account_names.account_id = ofx_accounts.id
    , null)) orelse return error.NoStatement;
    defer stmt.finalize() catch {};
    while ((try stmt.step()) != .Done) {
        // TODO: sqlite3 fix `columnText` null pointer seg fault
        const account_id = stmt.columnInt64(0);
        const ofx_hash = stmt.columnText(1);
        const account_name = @ptrCast(?[*:0]const u8, stmt.sqlite3_column_text(2));
        // TODO: Escape note text
        try out.print(
            \\<tr><td class="align-start"><a href="/ofx/accounts/{}">{s}</a></td><td class="align-start">
        , .{ account_id, ofx_hash });
        if (account_name) |name| {
            try out.print(
                \\<a href="/accounts/{}">{s}</a>
            , .{ std.zig.fmtEscapes(std.mem.span(name)), name });
        } else {
            try out.writeAll("null");
        }
        try out.writeAll("</td></tr>");
    }

    try out.writeAll(
        \\</tbody>
        \\</table>
        \\</body>
        \\</html>
    );
}

fn getOFXAccount(ctx: *Context, res: *http.Response, req: http.Request, captures: struct { account_id: []const u8 }) !void {
    _ = req;

    const account_id = try std.fmt.parseInt(i64, captures.account_id, 10);

    var out = res.writer();

    try res.headers.put("Content-Type", "text/html");
    try writeHTMLHeader(out, "OFX Account");

    try out.writeAll(
        \\<table>
    );

    var stmt = (try ctx.db.prepare_v2(
        \\SELECT ofx_accounts.hash, name
        \\FROM ofx_accounts
        \\LEFT JOIN ofx_account_names ON ofx_account_names.account_id = ofx_accounts.id
        \\WHERE ofx_accounts.id = ?
    , null)) orelse return error.NoStatement;
    defer stmt.finalize() catch {};
    try stmt.bindInt64(1, account_id);
    while ((try stmt.step()) != .Done) {
        const ofx_hash = stmt.columnText(0);
        const account_name = @ptrCast(?[*:0]const u8, stmt.sqlite3_column_text(1));
        try out.print(
            \\<tr><th>Hash</th><td><a href="/ofx/accounts/{}">{s}</a></tr>
        , .{ std.zig.fmtEscapes(ofx_hash), ofx_hash });

        try out.print(
            \\<tr><th>Account</th><td>
        , .{});
        if (account_name) |name| {
            try out.print(
                \\<a href="/accounts/{}">{s}</a>
            , .{ std.zig.fmtEscapes(std.mem.span(name)), name });
        } else {
            try out.print(
                \\<form>
                \\<input type="text" name="ofx-account-name" />
                \\<button hx-put="/ofx/accounts/{}">Submit</button>
                \\</form>
            , .{account_id});
        }
        try out.writeAll("</td></tr>");
    }

    try out.writeAll(
        \\</table>
        \\</body>
        \\</html>
    );
}

fn putOFXAccount(ctx: *Context, res: *http.Response, req: http.Request, captures: struct { account_id: []const u8 }) !void {
    _ = req;

    const account_id = try std.fmt.parseInt(i64, captures.account_id, 10);
    const account_name_opt = try req.formValue(ctx.allocator, "ofx-account-name");
    defer if (account_name_opt) |account_name| ctx.allocator.free(account_name);

    var out = res.writer();

    try res.headers.put("Content-Type", "text/html");
    try writeHTMLHeader(out, "OFX Account");

    if (account_name_opt) |account_name| {
        var stmt = (try ctx.db.prepare_v2(
            \\INSERT INTO ofx_account_names(account_id, name) VALUES (?, ?)
            \\ON CONFLICT(account_id) DO UPDATE SET name=excluded.name;
        , null)) orelse return error.NoStatement;
        defer stmt.finalize() catch {};
        try stmt.bindInt64(1, account_id);
        try stmt.bindText(2, account_name, .transient);
        while ((try stmt.step()) != .Done) {}

        try out.print(
            \\<div>Account {}'s name set to {s}</div>
        , .{ account_id, account_name });
    }

    try out.writeAll(
        \\</body>
        \\</html>
    );
}

fn getOFXLedgerBalances(ctx: *Context, res: *http.Response, req: http.Request) !void {
    _ = req;

    var out = res.writer();

    try res.headers.put("Content-Type", "text/html");
    try writeHTMLHeader(out, "OFX Ledger Balances");

    try out.writeAll(
        \\<table>
        \\<thead>
        \\<tr><th class="align-end">Posted</th><th class="align-start">Account</th><th class="align-end">Expectation</th><th class="align-end">Latest Balance Date</th><th class="align-end">Actual</th><th class="align-start">CUR</th></tr>
        \\</thead>
        \\<tbody>
    );

    var stmt = (try ctx.db.prepare_v2(
        \\SELECT
        \\  ofx_ledger_balance.day_posted,
        \\  max(ofx_running_balances.day_posted),
        \\  COALESCE(ofx_account_names.name, ofx_accounts.hash) AS hash_or_name,
        \\  ofx_ledger_balance.amount,
        \\  ofx_running_balances.balance,
        \\  currencies.name,
        \\  currencies.divisor
        \\FROM ofx_ledger_balance
        \\LEFT JOIN ofx_accounts ON ofx_accounts.id = ofx_ledger_balance.account_id
        \\LEFT JOIN currencies ON currencies.id = ofx_ledger_balance.currency_id
        \\LEFT JOIN ofx_account_names ON ofx_account_names.account_id = ofx_ledger_balance.account_id
        \\LEFT JOIN ofx_running_balances ON ofx_running_balances.account_id = ofx_ledger_balance.account_id AND (ofx_running_balances.day_posted <= ofx_ledger_balance.day_posted)
        \\GROUP BY ofx_ledger_balance.day_posted, hash_or_name, ofx_ledger_balance.currency_id
        \\ORDER BY ofx_ledger_balance.day_posted DESC
    , null)) orelse return error.NoStatement;
    defer stmt.finalize() catch {};
    while ((try stmt.step()) != .Done) {
        // TODO: sqlite3 fix `columnText` null pointer seg fault
        const day_posted = date_util.julianDayNumberToGregorianDate(@intCast(u64, stmt.columnInt64(0)));
        const latest_balance_day = date_util.julianDayNumberToGregorianDate(@intCast(u64, stmt.columnInt64(1)));
        const account_name = stmt.columnText(2);
        const ledger_balance = stmt.columnInt64(3);
        const running_balance = stmt.columnInt64(4);
        const currency_name = stmt.columnText(5);
        const currency_divisor = stmt.columnInt64(6);

        if (ledger_balance == running_balance) {
            try out.print(
                \\<tr>
                \\  <td class="align-end">{}</td>
                \\  <td class="align-start">{s}</td>
                \\  <td class="align-end">{}.{:0>2}</td>
                \\  <td class="align-end">{}</td>
                \\  <td class="align-end">{}.{:0>2}</td>
                \\  <td class="align-start">{s}</td>
                \\</tr>
            , .{
                day_posted.fmtISO(),
                account_name,
                @divTrunc(ledger_balance, currency_divisor),
                @intCast(u64, @mod(ledger_balance, currency_divisor)),
                latest_balance_day.fmtISO(),
                @divTrunc(running_balance, currency_divisor),
                @intCast(u64, @mod(running_balance, currency_divisor)),
                currency_name,
            });
        } else {
            try out.print(
                \\<tr class="error">
                \\  <td class="align-end">{}</td>
                \\  <td class="align-start">{s}</td>
                \\  <td class="align-end">{}.{:0>2}</td>
                \\  <td class="align-end">{}</td>
                \\  <td class="align-end">{}.{:0>2}</td>
                \\  <td class="align-start">{s}</td>
                \\</tr>
            , .{
                day_posted.fmtISO(),
                account_name,
                @divTrunc(ledger_balance, currency_divisor),
                @intCast(u64, @mod(ledger_balance, currency_divisor)),
                latest_balance_day.fmtISO(),
                @divTrunc(running_balance, currency_divisor),
                @intCast(u64, @mod(running_balance, currency_divisor)),
                currency_name,
            });
        }
    }

    try out.writeAll(
        \\</tbody>
        \\</table>
        \\</body>
        \\</html>
    );
}

fn getOFXTransactions(ctx: *Context, res: *http.Response, req: http.Request) !void {
    _ = req;

    var out = res.writer();

    try res.headers.put("Content-Type", "text/html");
    try writeHTMLHeader(out, "OFX Transactions");

    try out.writeAll(
        \\<table>
        \\<thead>
        \\<tr><th class="align-end">Posted</th><th class="align-start">Account</th><th class="align-end">Amount</th><th class="align-start">CUR</th><th class="align-start">Description</th></tr>
        \\</thead>
        \\<tbody>
    );

    var stmt = (try ctx.db.prepare_v2(
        \\SELECT
        \\  ofx_transactions.account_id,
        \\  ofx_transactions.id,
        \\  day_posted,
        \\  COALESCE(ofx_account_names.name, ofx_accounts.hash),
        \\  amount,
        \\  currencies.name,
        \\  currencies.divisor,
        \\  description
        \\FROM ofx_transactions
        \\LEFT JOIN ofx_accounts ON ofx_accounts.id = ofx_transactions.account_id
        \\LEFT JOIN currencies ON currencies.id = currency_id
        \\LEFT JOIN ofx_account_names ON ofx_account_names.account_id = ofx_accounts.id
        \\ORDER BY day_posted DESC
    , null)) orelse return error.NoStatement;
    defer stmt.finalize() catch {};
    while ((try stmt.step()) != .Done) {
        const account_id = stmt.columnInt64(0);
        const id = stmt.columnInt64(1);
        const day_posted = date_util.julianDayNumberToGregorianDate(@intCast(u64, stmt.columnInt64(2)));
        const account_hash = stmt.columnText(3);
        const amount = stmt.columnInt64(4);
        const currency_name = stmt.columnText(5);
        const currency_divisor = stmt.columnInt64(6);
        const description = stmt.columnText(7);
        // TODO: Escape note text
        try out.print(
            \\<tr><input type="hidden" name="ofx-account-id" values="{}"/><input type="hidden" name="ofx-transactions-id" values="{}"/>
            \\  <td class="align-end">{}</td>
            \\  <td class="align-start">{s}</td>
            \\  <td class="align-end">{}.{:0>2}</td>
            \\  <td class="align-start">{s}</td>
            \\  <td class="align-start">{s}</td>
            \\</tr>
        , .{
            account_id,
            id,
            day_posted.fmtISO(),
            account_hash,
            @divTrunc(amount, currency_divisor),
            @intCast(u64, @mod(amount, currency_divisor)),
            currency_name,
            description,
        });
    }

    try out.writeAll(
        \\</tbody>
        \\</table>
        \\</body>
        \\</html>
    );
}

fn postOFX(ctx: *Context, res: *http.Response, req: http.Request) !void {
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();

    var files_imported: usize = 0;

    const headers = try req.headers(arena.allocator());
    var multipart_iter = try multipart_form_data.parse(headers.get("Content-Type"), req.body());

    var txn = try Transaction.begin(@src(), ctx.db);
    defer txn.deinit();

    while (try multipart_iter.next()) |part| {
        const form_name = part.formName() orelse continue;
        if (std.mem.eql(u8, "file", std.mem.trim(u8, form_name, "\""))) {
            try importOFXFile(ctx.db, arena.allocator(), part.body);
            files_imported += 1;
        }
    }

    try txn.commit();

    try res.headers.put("Content-Type", "text/html");
    var out = res.writer();

    try writeHTMLHeader(out, "Import OFX");

    try out.print(
        \\Successfully imported {} files
        \\</body>
        \\</html>
    , .{files_imported});
}

fn importOFXFile(db: *sqlite3.SQLite3, allocator: std.mem.Allocator, src: []const u8) !void {
    var txn = try Transaction.begin(@src(), db);
    defer txn.deinit();

    const ofx_events = try ofx_sgml.parse(allocator, src);
    defer allocator.free(ofx_events);

    var stmt_insert_transaction = (try db.prepare_v2(
        \\INSERT OR IGNORE INTO ofx_transactions(account_id, id, day_posted, amount, currency_id, description)
        \\VALUES (?, ?, ?, ?, ?, ? || COALESCE(?, ''))
    , null)) orelse return error.NoStatement;
    defer stmt_insert_transaction.finalize() catch {};

    var fid: ?[]const u8 = null;
    var org: ?[]const u8 = null;
    var account_id: ?i64 = null;
    var currency: ?Currency = null;
    var transaction: struct {
        id: ?[]const u8 = null,
        day_posted: ?i64 = null,
        amount: ?i64 = null,
        name: ?[]const u8 = null,
        memo: ?[]const u8 = null,
    } = undefined;
    var balance: struct {
        day_posted: ?i64 = null,
        amount: ?i64 = null,
    } = undefined;
    for (ofx_events) |event| {
        switch (event) {
            .fid => |loc| fid = loc.text(src),
            .org => |loc| org = loc.text(src),
            .close_fi => try putFiOrg(db, fid orelse return error.NoFID, org orelse return error.NoOrg),

            .acctid => |loc| account_id = try getOrPutAccountByHash(db, fid orelse return error.NoBankId, loc.text(src)),
            .curdef => |loc| currency = try getCurrencyByName(db, loc.text(src)),

            .start_stmttrn => transaction = .{},
            .fitid => |loc| transaction.id = loc.text(src),
            .name => |loc| transaction.name = loc.text(src),
            .memo => |loc| transaction.memo = loc.text(src),
            .dtposted => |loc| {
                const text = loc.text(src);
                if (text.len < 8) continue;
                const julian_day_number = date_util.gregorianDateToJulianDayNumber(.{
                    .year = try std.fmt.parseInt(i16, text[0..4], 10),
                    .month = try std.fmt.parseInt(u4, text[4..6], 10),
                    .day = try std.fmt.parseInt(u5, text[6..8], 10),
                });
                transaction.day_posted = @intCast(i64, julian_day_number);
            },
            .trnamt => |loc| {
                const text = loc.text(src);
                const major_str_end = std.mem.indexOf(u8, text, ".") orelse text.len;
                const major_str = text[0..major_str_end];
                const minor_str = std.mem.trimLeft(u8, text[major_str_end..], ".");
                transaction.amount = (try std.fmt.parseInt(i64, major_str, 10)) * currency.?.divisor + (try std.fmt.parseInt(i64, minor_str, 10));
            },
            .close_stmttrn => {
                try stmt_insert_transaction.reset();
                try stmt_insert_transaction.bindInt64(1, account_id orelse return error.NoAccountId);
                try stmt_insert_transaction.bindText(2, transaction.id orelse return error.NoTransactionId, .transient);
                try stmt_insert_transaction.bindInt64(3, transaction.day_posted orelse return error.NoDayPosted);
                try stmt_insert_transaction.bindInt64(4, transaction.amount orelse return error.NoAmount);
                try stmt_insert_transaction.bindInt64(5, if (currency) |c| c.id else return error.NoCurrency);
                try stmt_insert_transaction.bindText(6, transaction.name, .transient);
                if (transaction.memo) |memo| {
                    try stmt_insert_transaction.bindText(7, memo, .transient);
                } else {
                    try stmt_insert_transaction.bindNull(7);
                }
                while ((try stmt_insert_transaction.step()) != .Done) {}
                transaction = undefined;
            },

            .start_balance => balance = .{},
            .balamt => |loc| {
                const text = loc.text(src);
                const major_str_end = std.mem.indexOf(u8, text, ".") orelse text.len;
                const major_str = text[0..major_str_end];
                const minor_str = std.mem.trimLeft(u8, text[major_str_end..], ".");
                balance.amount = (try std.fmt.parseInt(i64, major_str, 10)) * currency.?.divisor + (try std.fmt.parseInt(i64, minor_str, 10));
            },
            .dtasof => |loc| {
                const text = loc.text(src);
                if (text.len < 8) continue;
                const julian_day_number = date_util.gregorianDateToJulianDayNumber(.{
                    .year = try std.fmt.parseInt(i16, text[0..4], 10),
                    .month = try std.fmt.parseInt(u4, text[4..6], 10),
                    .day = try std.fmt.parseInt(u5, text[6..8], 10),
                });
                balance.day_posted = @intCast(i64, julian_day_number);
            },
            .close_balance => |kind| {
                if (kind == .ledger) {
                    var stmt = (try db.prepare_v2(
                        \\INSERT OR IGNORE INTO ofx_ledger_balance(account_id, day_posted, amount, currency_id)
                        \\VALUES (?, ?, ?, ?)
                    , null)) orelse return error.NoStatement;
                    defer stmt.finalize() catch {};
                    try stmt.bindInt64(1, account_id orelse return error.NoAccountId);
                    try stmt.bindInt64(2, balance.day_posted orelse return error.NoDayPosted);
                    try stmt.bindInt64(3, balance.amount orelse return error.NoAmount);
                    try stmt.bindInt64(4, if (currency) |c| c.id else return error.NoCurrency);
                    while ((try stmt.step()) != .Done) {}
                }
                balance = undefined;
            },

            else => {},
        }
    }

    try txn.commit();
}

fn debugParseOFX(ctx: *Context, res: *http.Response, req: http.Request) !void {
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

fn putFiOrg(db: *sqlite3.SQLite3, fid: []const u8, org: []const u8) !void {
    var stmt = (try db.prepare_v2("INSERT OR IGNORE INTO ofx_financial_institutions(fid, org) VALUES (?, ?)", null)) orelse return error.NoStatement;
    defer stmt.finalize() catch {};
    try stmt.bindText(1, fid, .transient);
    try stmt.bindText(2, org, .transient);
    while ((try stmt.step()) != .Done) {}
}

fn getOrPutAccountByHash(db: *sqlite3.SQLite3, fid: []const u8, acctid: []const u8) !i64 {
    var hash: [16]u8 = undefined;
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(fid);
    hasher.update(&.{0});
    hasher.update(acctid);
    hasher.final(&hash);

    var hash_buf: [40]u8 = undefined;
    const hash_str = try std.fmt.bufPrintZ(&hash_buf, "blake3-{}", .{std.fmt.fmtSliceHexLower(&hash)});

    {
        var stmt = (try db.prepare_v2("INSERT OR IGNORE INTO ofx_accounts(fiid, hash) VALUES (?, ?)", null)) orelse return error.NoStatement;
        defer stmt.finalize() catch {};
        try stmt.bindText(1, fid, .transient);
        try stmt.bindText(2, hash_str, .transient);
        while ((try stmt.step()) != .Done) {}
    }

    var stmt = (try db.prepare_v2("SELECT id FROM ofx_accounts WHERE hash LIKE ?", null)) orelse return error.NoStatement;
    try stmt.bindText(1, hash_str, .transient);
    while ((try stmt.step()) != .Done) {
        const id = stmt.columnInt64(0);
        return id;
    }
    return error.AccountNotFound;
}

const Currency = struct {
    id: i64,
    divisor: i64,
};

fn getCurrencyByName(db: *sqlite3.SQLite3, name: []const u8) !Currency {
    var stmt = (try db.prepare_v2("SELECT id, divisor FROM currencies WHERE name LIKE ?", null)) orelse return error.NoStatement;
    try stmt.bindText(1, name, .transient);
    while ((try stmt.step()) != .Done) {
        return Currency{
            .id = stmt.columnInt64(0),
            .divisor = stmt.columnInt64(1),
        };
    }
    return error.CurrencyNotFound;
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
