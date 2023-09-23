const std = @import("std");
const sqlite3 = @import("sqlite3");

/// - https://david.rothlis.net/declarative-schema-migration-for-sqlite/
/// - https://sqlite.org/pragma.html#pragma_table_info
/// - https://www.sqlite.org/lang_altertable.html
///   - alter table cannot move a table to a different attached database
///
/// TODO: Check columns of tables
pub fn ensureSchema(allocator: std.mem.Allocator, db: *sqlite3.SQLite3, pristineSchema: [:0]const u8) !void {
    var txn = try Transaction.begin(std.fmt.comptimePrint("{s}::{s}", .{ @src().file, @src().fn_name }), db);
    defer txn.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var pristine = try sqlite3.SQLite3.open(":memory:");
    defer pristine.close() catch @panic("Couldn't close db connection");
    try executeScript(pristine, pristineSchema);

    var pristine_tables = try dbTables(arena.allocator(), pristine);
    var current_tables = try dbTables(arena.allocator(), db);

    // set(pristine) - set(db) = new_tables
    var pristine_table_iter = pristine_tables.iterator();
    while (pristine_table_iter.next()) |pristine_table_entry| {
        const table_name = pristine_table_entry.key_ptr.*;
        if (current_tables.get(table_name)) |current_table_info| {
            // The table already exists
            if (current_table_info.eql(pristine_table_entry.value_ptr.*)) {
                // The tables are identical, nothing needs to change
                continue;
            }
            // The tables are not identical, we need to rebuild it
            try dbRebuildTable(allocator, db, pristine, pristine_table_entry.value_ptr.*);
            continue;
        }
        // Create table in current database that is in pristine database
        try db.exec(pristine_table_entry.value_ptr.sql, null, null, null);
    }

    // set(db) - set(pristine)  = removed_tables
    var current_table_iter = current_tables.iterator();
    while (current_table_iter.next()) |current_table_entry| {
        const table_name = current_table_entry.key_ptr.*;
        if (pristine_tables.contains(table_name)) {
            // The table exists in the pristine, no need to drop it
            continue;
        }
        // Drop table in current database that is not in pristine database
        const drop_sql = try std.fmt.allocPrintZ(arena.allocator(), "DROP TABLE {s}", .{table_name});
        try db.exec(drop_sql, null, null, null);
    }

    try txn.commit();
}

pub const TableInfo = struct {
    schema: [:0]const u8,
    name: [:0]const u8,
    table_type: Type,
    ncol: u32,
    without_rowid: bool,
    strict: bool,
    sql: [:0]const u8,

    const Type = enum {
        table,
        view,
        shadow,
        virtual,
    };

    pub fn eql(a: @This(), b: @This()) bool {
        return std.mem.eql(u8, a.schema, b.schema) and
            std.mem.eql(u8, a.name, b.name) and
            a.table_type == b.table_type and
            a.ncol == b.ncol and
            a.without_rowid == b.without_rowid and
            a.strict == b.strict and
            std.mem.eql(u8, a.sql, b.sql);
    }
};

/// - sqlite 3.37 introduced `PRAGMA table_list`: https://sqlite.org/pragma.html#pragma_table_list
pub fn dbTables(allocator: std.mem.Allocator, db: *sqlite3.SQLite3) !std.StringHashMap(TableInfo) {
    var stmt = (try db.prepare_v2(
        \\ SELECT tl.schema, tl.name, tl.type, tl.ncol, tl.wr, tl.strict, schema.sql
        \\ FROM pragma_table_list AS tl
        \\ JOIN sqlite_schema AS schema ON schema.name = tl.name
    , null)).?;
    defer stmt.finalize() catch unreachable;

    var hashmap = std.StringHashMap(TableInfo).init(allocator);
    errdefer hashmap.deinit();
    while ((try stmt.step()) != .Done) {
        if (std.mem.startsWith(u8, stmt.columnText(1) orelse continue, "sqlite_")) {
            continue;
        }

        const schema = try allocator.dupeZ(u8, stmt.columnText(0).?);
        const name = try allocator.dupeZ(u8, stmt.columnText(1).?);
        const table_type = std.meta.stringToEnum(TableInfo.Type, stmt.columnText(2).?).?;
        const ncol = @as(u32, @intCast(stmt.columnInt(3)));
        const without_rowid = stmt.columnInt(4) != 0;
        const strict = stmt.columnInt(5) != 0;
        const sql = try allocator.dupeZ(u8, stmt.columnText(6).?);

        const fullname = try std.fmt.allocPrint(allocator, "\"{}\".\"{}\"", .{ std.zig.fmtEscapes(schema), std.zig.fmtEscapes(name) });
        try hashmap.putNoClobber(fullname, .{
            .schema = schema,
            .name = name,
            .table_type = table_type,
            .ncol = ncol,
            .without_rowid = without_rowid,
            .strict = strict,
            .sql = sql,
        });
    }

    return hashmap;
}

/// - sqlite 3.37 introduced `PRAGMA table_list`: https://sqlite.org/pragma.html#pragma_table_list
fn dbRebuildTable(allocator: std.mem.Allocator, db: *sqlite3.SQLite3, pristine: *sqlite3.SQLite3, new_table_info: TableInfo) !void {
    var common_cols_list = std.StringArrayHashMap(bool).init(allocator);
    defer {
        for (common_cols_list.keys()) |str| {
            allocator.free(str);
        }
        common_cols_list.deinit();
    }

    {
        var stmt = (try db.prepare_v2(
            \\ SELECT name FROM pragma_table_info(?)
        , null)).?;
        defer stmt.finalize() catch unreachable;
        try stmt.bindText(1, new_table_info.name, .transient);
        while ((try stmt.step()) != .Done) {
            try common_cols_list.putNoClobber(try allocator.dupe(u8, stmt.columnText(0).?), false);
        }
    }

    {
        var stmt = (try pristine.prepare_v2(
            \\ SELECT name FROM pragma_table_info(?)
        , null)).?;
        defer stmt.finalize() catch unreachable;
        try stmt.bindText(1, new_table_info.name, .transient);
        while ((try stmt.step()) != .Done) {
            if (common_cols_list.getPtr(stmt.columnText(0).?)) |in_both| {
                in_both.* = true;
            }
        }
    }

    var common_cols = std.ArrayList(u8).init(allocator);
    defer common_cols.deinit();
    {
        var common_col_iter = common_cols_list.iterator();
        while (common_col_iter.next()) |entry| {
            const in_both = entry.value_ptr.*;
            if (in_both) {
                const need_comma = common_cols.items.len > 0;
                if (need_comma) {
                    try common_cols.appendSlice(", ");
                }
                try common_cols.appendSlice(entry.key_ptr.*);
            }
        }
    }

    if (new_table_info.table_type != .table) {
        std.log.warn("Skipping table {s}. Tables of type {} not supported. Only regular tables supported ATM.", .{ new_table_info.name, new_table_info.table_type });
        return;
    }
    try db.exec("PRAGMA foreign_keys=OFF;", null, null, null);
    defer db.exec("PRAGMA foreign_keys=ON;", null, null, null) catch {};

    var txn = try Transaction.begin(std.fmt.comptimePrint("{s}::{s}", .{ @src().file, @src().fn_name }), db);
    defer txn.deinit();
    const table_migration_name = try std.fmt.allocPrint(allocator,
        \\"{}_migration_new"
    , .{std.zig.fmtEscapes(new_table_info.name)});
    defer allocator.free(table_migration_name);

    const create_sql = try std.mem.replaceOwned(u8, allocator, new_table_info.sql, new_table_info.name, table_migration_name);
    defer allocator.free(create_sql);
    const create_sql_z = try std.fmt.allocPrintZ(allocator, "{s}", .{create_sql});
    defer allocator.free(create_sql_z);
    try db.exec(create_sql_z, null, null, null);

    const insert_sql = try std.fmt.allocPrintZ(allocator,
        \\INSERT INTO "{}".{s} ({s}) SELECT {s} FROM "{}"
    , .{ std.zig.fmtEscapes(new_table_info.schema), table_migration_name, common_cols.items, common_cols.items, std.zig.fmtEscapes(new_table_info.name) });
    defer allocator.free(insert_sql);
    try db.exec(insert_sql, null, null, null);

    const drop_sql = try std.fmt.allocPrintZ(allocator,
        \\DROP TABLE "{}"
    , .{std.zig.fmtEscapes(new_table_info.name)});
    defer allocator.free(drop_sql);
    try db.exec(drop_sql, null, null, null);

    const alter_sql = try std.fmt.allocPrintZ(allocator,
        \\ALTER TABLE {s} RENAME TO "{}"
    , .{ table_migration_name, std.zig.fmtEscapes(new_table_info.name) });
    defer allocator.free(alter_sql);
    try db.exec(alter_sql, null, null, null);

    try db.exec("PRAGMA foreign_keys_check;", null, null, null);

    try txn.commit();
}

pub fn executeScript(db: *sqlite3.SQLite3, sql: [:0]const u8) !void {
    try db.exec(sql, null, null, null);
}

pub const Transaction = struct {
    db: *sqlite3.SQLite3,
    commit_sql: ?[:0]const u8,
    rollback_sql: ?[:0]const u8,

    pub fn begin(comptime SAVEPOINT: []const u8, db: *sqlite3.SQLite3) !@This() {
        try db.exec(comptime std.fmt.comptimePrint("SAVEPOINT \"{}\"", .{std.zig.fmtEscapes(SAVEPOINT)}), null, null, null);
        return @This(){
            .db = db,
            .commit_sql = comptime std.fmt.comptimePrint("RELEASE \"{}\"", .{std.zig.fmtEscapes(SAVEPOINT)}),
            .rollback_sql = comptime std.fmt.comptimePrint("ROLLBACK TO \"{}\"", .{std.zig.fmtEscapes(SAVEPOINT)}),
        };
    }

    pub fn deinit(this: *@This()) void {
        if (this.rollback_sql) |rollback| {
            this.db.exec(rollback, null, null, null) catch {};
            this.commit_sql = null;
            this.rollback_sql = null;
        }
        this.db = undefined;
    }

    pub fn commit(this: *@This()) !void {
        if (this.commit_sql) |rollback| {
            try this.db.exec(rollback, null, null, null);
            this.commit_sql = null;
            this.rollback_sql = null;
        }
    }
};
