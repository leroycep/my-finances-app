gpa: std.mem.Allocator,
db: *sqlite3.SQLite3,
window: *c.GLFWwindow,

canvas: Canvas,

db_path: []const u8 = "",

update_table_list: bool = true,
table_list_arena: std.heap.ArenaAllocator,
table_list: std.StringHashMapUnmanaged(sqlite_utils.TableInfo) = .{},

const App = @This();

pub const InitOptions = struct {
    visible: bool = true,
    resizable: bool = true,
};

pub fn init(gpa: std.mem.Allocator, db: *sqlite3.SQLite3, options: InitOptions) !*@This() {
    const app = try gpa.create(@This());
    errdefer gpa.destroy(app);

    // Set opengl attributes
    c.glfwWindowHint(c.GLFW_VISIBLE, if (options.visible) c.GLFW_TRUE else c.GLFW_FALSE);
    c.glfwWindowHint(c.GLFW_RESIZABLE, if (options.resizable) c.GLFW_TRUE else c.GLFW_FALSE);
    c.glfwWindowHint(c.GLFW_OPENGL_DEBUG_CONTEXT, c.GLFW_TRUE);
    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_OPENGL_ES_API);
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MAJOR, 3);
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MINOR, 0);

    //  Open window
    const window = c.glfwCreateWindow(640, 640, "My Finances App", null, null) orelse return error.GlfwCreateWindow;
    errdefer c.glfwDestroyWindow(window);
    _ = c.glfwSetFramebufferSizeCallback(window, &glfw_framebuffer_size_callback);

    c.glfwMakeContextCurrent(window);

    main.gl_binding.init(GlBindingLoader);
    gl.makeBindingCurrent(&main.gl_binding);

    // Set up input callbacks
    c.glfwSetWindowUserPointer(window, app);

    const canvas = try Canvas.init(gpa, .{});
    errdefer canvas.deinit(gpa);

    app.* = .{
        .gpa = gpa,
        .db = db,
        .window = window,

        .canvas = canvas,
        .table_list_arena = std.heap.ArenaAllocator.init(app.gpa),
    };

    return app;
}

pub fn deinit(app: *@This()) void {
    app.table_list_arena.deinit();
    app.canvas.deinit(app.gpa);
    c.glfwDestroyWindow(app.window);
    app.gpa.destroy(app);
}

pub fn render(app: *@This()) void {
    if (app.update_table_list) blk: {
        _ = app.table_list_arena.reset(.retain_capacity);
        const tables = sqlite_utils.dbTables(app.table_list_arena.allocator(), app.db) catch break :blk;
        app.table_list = tables.unmanaged;
        app.update_table_list = false;
    }

    var window_size: [2]c_int = undefined;
    c.glfwGetWindowSize(app.window, &window_size[0], &window_size[1]);
    const window_sizef = [2]f32{
        @floatFromInt(window_size[0]),
        @floatFromInt(window_size[1]),
    };
    const projection = utils.mat4.orthographic(
        f32,
        -0.5,
        (window_sizef[0] - 1.0) + 0.5,
        (window_sizef[1] - 1.0) + 0.5,
        -0.5,
        -1,
        1,
    );

    app.canvas.begin(.{ .projection = projection });
    _ = app.canvas.printText("db_path = \"{}\"", .{std.zig.fmtEscapes(app.db_path)}, .{
        .pos = .{ 0, 0 },
        .baseline = .top,
        .@"align" = .left,
    });

    var y: f32 = app.canvas.font.lineHeight;
    var table_iterator = app.table_list.iterator();
    while (table_iterator.next()) |entry| {
        y += app.canvas.writeText(entry.value_ptr.sql, .{
            .pos = .{ 0, y },
            .baseline = .top,
            .@"align" = .left,
        })[1];
    }

    y += app.canvas.font.lineHeight;

    {
        var stmt = (app.db.prepare_v2("SELECT id, hash, fiid FROM ofx_accounts", null) catch unreachable).?;
        defer stmt.finalize() catch unreachable;

        y += app.canvas.printText("{s} {s} {s}", .{ "id", "hash", "fiid" }, .{
            .pos = .{ 0, y },
        })[1];

        while ((stmt.step() catch unreachable) != .Done) {
            const id = stmt.columnInt64(0);
            const hash = stmt.columnText(1);
            const fiid = stmt.columnText(2);

            y += app.canvas.printText("{?d} {?s} {?s}", .{ id, hash, fiid }, .{
                .pos = .{ 0, y },
            })[1];
        }
    }

    y += app.canvas.font.lineHeight;

    {
        var stmt = (app.db.prepare_v2(
            \\SELECT ofx_account_names.name, olb.day_posted, olb.amount, currencies.name
            \\FROM ofx_ledger_balance AS olb
            \\JOIN currencies ON olb.currency_id = currencies.id
            \\JOIN ofx_account_names ON olb.account_id = ofx_account_names.account_id
        , null) catch unreachable).?;
        defer stmt.finalize() catch unreachable;

        y += app.canvas.printText("{s} {s} {s} {s}", .{ "account", "day_posted", "amount", "currency_id" }, .{
            .pos = .{ 0, y },
        })[1];

        while ((stmt.step() catch unreachable) != .Done) {
            const account_name = stmt.columnText(0);
            const day_posted = stmt.columnInt64(1);
            const amount = stmt.columnInt64(2);
            const currency_name = stmt.columnText(3);

            y += app.canvas.printText("{?s} {?d} {?d} {?s}", .{ account_name, day_posted, amount, currency_name }, .{
                .pos = .{ 0, y },
            })[1];
        }
    }
    app.canvas.end();
}

const GlBindingLoader = struct {
    const AnyCFnPtr = *align(@alignOf(fn () callconv(.C) void)) const anyopaque;

    pub fn getCommandFnPtr(command_name: [:0]const u8) ?AnyCFnPtr {
        return c.glfwGetProcAddress(command_name);
    }

    pub fn extensionSupported(extension_name: [:0]const u8) bool {
        return c.glfwExtensionSupported(extension_name);
    }
};

fn glfw_framebuffer_size_callback(window: ?*c.GLFWwindow, width: c_int, height: c_int) callconv(.C) void {
    const app = @as(*App, @alignCast(@ptrCast(c.glfwGetWindowUserPointer(window))));
    _ = app;
    gl.viewport(
        0,
        0,
        @intCast(width),
        @intCast(height),
    );
}

const std = @import("std");
const sqlite3 = @import("sqlite3");
const gl = @import("gl");
const utils = @import("utils");
const c = @import("./c.zig");
const main = @import("./main.zig");
const Canvas = @import("./Canvas.zig");
const sqlite_utils = @import("./sqlite-utils.zig");
