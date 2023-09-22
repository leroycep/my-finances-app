gpa: std.mem.Allocator,
db: *sqlite3.SQLite3,
window: *c.GLFWwindow,

canvas: Canvas,

db_path: []const u8 = "",

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
    };

    return app;
}

pub fn deinit(app: *@This()) void {
    app.canvas.deinit(app.gpa);
    c.glfwDestroyWindow(app.window);
    app.gpa.destroy(app);
}

pub fn render(app: *@This()) void {
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
    app.canvas.printText("db_path = \"{}\"", .{std.zig.fmtEscapes(app.db_path)}, .{
        .pos = .{ 0, 0 },
        .baseline = .top,
        .@"align" = .left,
    });
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
