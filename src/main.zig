const std = @import("std");
const sqlite3 = @import("sqlite3");
const sqlite_utils = @import("./sqlite-utils.zig");
const c = @import("./c.zig");
const gl = @import("gl");

const App = @import("./App.zig");

const APP_NAME = "my-finances-app";

pub var gl_binding: gl.Binding = undefined;
pub fn main() anyerror!void {
    var std_heap_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = std_heap_gpa.deinit();
    const gpa = std_heap_gpa.allocator();

    const data_dir_path = try std.fs.getAppDataDir(gpa, APP_NAME);
    defer gpa.free(data_dir_path);

    std.log.info("data dir = \"{}\"", .{std.zig.fmtEscapes(data_dir_path)});

    var data_dir = try std.fs.cwd().makeOpenPath(data_dir_path, .{});
    defer data_dir.close();

    const db_path_z = try std.fs.path.joinZ(gpa, &.{ data_dir_path, "finances.db" });
    defer gpa.free(db_path_z);

    _ = try sqlite3.checkSqliteErr(sqlite3.sqlite3_config(@intFromEnum(sqlite3.ConfigOption.log), sqliteLogCallback, @as(?*anyopaque, null)));

    std.log.info("opening database = \"{}\"", .{std.zig.fmtEscapes(db_path_z)});
    var db = try sqlite3.SQLite3.open(db_path_z);
    defer db.close() catch @panic("Couldn't close sqlite database");
    try setupSchema(gpa, db);

    // Pre-emptively load libraries so GLFW will detect wayland
    try loadDynamicLibraries(gpa);

    // GLFW setup
    _ = c.glfwSetErrorCallback(&error_callback_for_glfw);

    const glfw_init_res = c.glfwInit();
    if (glfw_init_res != 1) {
        std.debug.print("glfw init error: {}\n", .{glfw_init_res});
        std.process.exit(1);
    }
    defer c.glfwTerminate();

    var app = try App.init(gpa, db, .{});
    defer app.deinit();

    // Main loop
    while (c.glfwWindowShouldClose(app.window) != c.GLFW_TRUE) {
        c.glfwPollEvents();

        gl.enable(gl.DEPTH_TEST);
        gl.clearColor(0, 0, 0, 1.0);
        gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

        c.glfwSwapBuffers(app.window);
    }
}

fn setupSchema(allocator: std.mem.Allocator, db: *sqlite3.SQLite3) !void {
    var txn = try sqlite_utils.Transaction.begin(std.fmt.comptimePrint("{s}::{s}", .{ @src().file, @src().fn_name }), db);
    defer txn.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    try sqlite_utils.ensureSchema(allocator, db, @embedFile("./schema.sql"));

    try sqlite_utils.executeScript(db, @embedFile("./defaults.sql"));

    try txn.commit();
}

fn loadDynamicLibraries(gpa: std.mem.Allocator) !void {
    var path_arena_allocator = std.heap.ArenaAllocator.init(gpa);
    defer path_arena_allocator.deinit();
    const arena = path_arena_allocator.allocator();

    var prefixes_to_try = std.ArrayList([]const u8).init(arena);

    try prefixes_to_try.append(try arena.dupe(u8, "."));
    if (std.process.getEnvVarOwned(arena, "NIX_LD_LIBRARY_PATH")) |path_list| {
        var path_list_iter = std.mem.tokenize(u8, path_list, ":");
        while (path_list_iter.next()) |path| {
            try prefixes_to_try.append(path);
        }
    } else |_| {}

    var path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const exe_dir_path = try std.fs.selfExeDirPath(&path_buf);
    var dir_to_search_opt: ?[]const u8 = exe_dir_path;
    while (dir_to_search_opt) |dir_to_search| : (dir_to_search_opt = std.fs.path.dirname(dir_to_search)) {
        try prefixes_to_try.append(try std.fs.path.join(arena, &.{ dir_to_search, "lib" }));
    }

    _ = tryLoadFromPrefixes(arena, prefixes_to_try.items, "libwayland-client.so") catch {};
    _ = tryLoadFromPrefixes(arena, prefixes_to_try.items, "libwayland-cursor.so") catch {};
    _ = tryLoadFromPrefixes(arena, prefixes_to_try.items, "libwayland-egl.so") catch {};
    _ = tryLoadFromPrefixes(arena, prefixes_to_try.items, "libxkbcommon.so") catch {};
    _ = tryLoadFromPrefixes(arena, prefixes_to_try.items, "libEGL.so") catch {};
}

fn tryLoadFromPrefixes(gpa: std.mem.Allocator, prefixes: []const []const u8, library_name: []const u8) !std.DynLib {
    for (prefixes) |prefix| {
        const path = try std.fs.path.join(gpa, &.{ prefix, library_name });
        defer gpa.free(path);

        const lib = std.DynLib.open(path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        return lib;
    }
    return error.FileNotFound;
}

fn sqliteLogCallback(userdata: *anyopaque, errcode: c_int, msg: ?[*:0]const u8) callconv(.C) void {
    _ = userdata;
    _ = errcode;
    _ = msg;
    // std.log.scoped(.sqlite3).err("{s}: {?s}", .{ sqlite3.errstr(errcode), msg });
}

fn error_callback_for_glfw(err: c_int, description: ?[*:0]const u8) callconv(.C) void {
    std.debug.print("Error 0x{x}: {?s}\n", .{ err, description });
}
