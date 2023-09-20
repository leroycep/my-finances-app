gpa: std.mem.Allocator,
db: *sqlite3.SQLite3,
window: *c.GLFWwindow,

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
    const window = c.glfwCreateWindow(640, 640, "Capture - Scatterometer", null, null) orelse return error.GlfwCreateWindow;
    errdefer c.glfwDestroyWindow(window);

    c.glfwMakeContextCurrent(window);

    main.gl_binding.init(GlBindingLoader);
    gl.makeBindingCurrent(&main.gl_binding);

    // Set up input callbacks
    c.glfwSetWindowUserPointer(window, app);

    app.* = .{
        .gpa = gpa,
        .db = db,
        .window = window,
    };

    return app;
}

pub fn deinit(app: *@This()) void {
    c.glfwDestroyWindow(app.window);
    app.gpa.destroy(app);
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

const std = @import("std");
const sqlite3 = @import("sqlite3");
const c = @import("./c.zig");
const main = @import("./main.zig");
const gl = @import("gl");
