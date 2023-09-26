gpa: std.mem.Allocator,
db: *sqlite3.SQLite3,
window: *c.GLFWwindow,

canvas: Canvas,

db_path: []const u8 = "",

update_table_list: bool = true,
table_list_arena: std.heap.ArenaAllocator,
table_list: std.StringHashMapUnmanaged(sqlite_utils.TableInfo) = .{},

ui_manager: ui.Manager,

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
    _ = c.glfwSetKeyCallback(window, &glfw_key_callback);
    _ = c.glfwSetMouseButtonCallback(window, &glfw_mousebutton_callback);
    _ = c.glfwSetCursorPosCallback(window, &glfw_cursor_pos_callback);
    _ = c.glfwSetCharCallback(window, &glfw_char_callback);
    _ = c.glfwSetScrollCallback(window, &glfw_scroll_callback);
    _ = c.glfwSetWindowSizeCallback(window, &glfw_window_size_callback);
    _ = c.glfwSetFramebufferSizeCallback(window, &glfw_framebuffer_size_callback);

    var canvas = try Canvas.init(gpa, .{});
    errdefer canvas.deinit(gpa);

    app.* = .{
        .gpa = gpa,
        .db = db,
        .window = window,

        .canvas = canvas,
        .table_list_arena = std.heap.ArenaAllocator.init(app.gpa),

        .ui_manager = ui.Manager{ .gpa = gpa, .font = &app.canvas.font },
    };

    const flexbox = try app.ui_manager.create(ui.Flexbox);
    defer flexbox.element.release();

    const currencies_button = try app.ui_manager.create(ui.Button);
    defer currencies_button.element.release();
    currencies_button.text = "Currencies";
    currencies_button.userdata = app;
    currencies_button.on_click_fn = onCurrenciesButtonPressed;
    try flexbox.appendChild(&currencies_button.element);

    const ofx_accounts_button = try app.ui_manager.create(ui.Button);
    defer ofx_accounts_button.element.release();
    ofx_accounts_button.text = "OFX accounts";
    ofx_accounts_button.userdata = app;
    ofx_accounts_button.on_click_fn = onOFXAccountsButtonPressed;
    try flexbox.appendChild(&ofx_accounts_button.element);

    const ledger_balances_button = try app.ui_manager.create(ui.Button);
    defer ledger_balances_button.element.release();
    ledger_balances_button.text = "Ledger Balances";
    ledger_balances_button.userdata = app;
    ledger_balances_button.on_click_fn = onLedgerBalancesButtonPressed;
    try flexbox.appendChild(&ledger_balances_button.element);

    const ofx_transactions_button = try app.ui_manager.create(ui.Button);
    defer ofx_transactions_button.element.release();
    ofx_transactions_button.text = "OFX Transactions";
    ofx_transactions_button.userdata = app;
    ofx_transactions_button.on_click_fn = onOFXTransactionsButtonPressed;
    try flexbox.appendChild(&ofx_transactions_button.element);

    app.ui_manager.setRoot(&flexbox.element);

    return app;
}

pub fn deinit(app: *@This()) void {
    app.ui_manager.deinit();
    app.table_list_arena.deinit();
    app.canvas.deinit(app.gpa);
    c.glfwDestroyWindow(app.window);
    app.gpa.destroy(app);
}

pub fn onCurrenciesButtonPressed(userdata: ?*anyopaque, _: *ui.Button) void {
    const app: *App = @ptrCast(@alignCast(userdata.?));

    const popup = app.ui_manager.create(ui.Popup) catch @panic("OOM");
    defer popup.element.release();
    popup.title = "Currencies";
    popup.element.rect.size = .{ 400, 400 };

    const flexbox = app.ui_manager.create(ui.Flexbox) catch @panic("OOM");
    defer flexbox.element.release();
    popup.setChild(&flexbox.element);

    var stmt = (app.db.prepare_v2("SELECT id, day_opened, name, divisor FROM currencies", null) catch unreachable).?;
    defer stmt.finalize() catch unreachable;

    while ((stmt.step() catch unreachable) != .Done) {
        const id = stmt.columnInt64(0);
        const date_opened = date_util.julianDayNumberToGregorianDate(@as(u64, @intCast(stmt.columnInt64(1))));
        const name = stmt.columnText(2);
        const divisor = stmt.columnInt64(3);

        const row_text = std.fmt.allocPrint(app.gpa, "{?} | {?} | {?s} | {?}", .{ id, date_opened.fmtISO(), name, divisor }) catch @panic("OOM");

        const label = app.ui_manager.create(ui.Label) catch @panic("OOM");
        defer label.element.release();
        app.gpa.free(label.text);
        label.text = row_text;
        flexbox.appendChild(&label.element) catch @panic("OOM");
    }

    app.ui_manager.addPopup(&popup.element) catch @panic("OOM");
}

pub fn onOFXAccountsButtonPressed(userdata: ?*anyopaque, _: *ui.Button) void {
    const app: *App = @ptrCast(@alignCast(userdata.?));

    const popup = app.ui_manager.create(ui.Popup) catch @panic("OOM");
    defer popup.element.release();
    popup.title = "OFX Accounts";
    popup.element.rect.size = .{ 400, 400 };

    const flexbox = app.ui_manager.create(ui.Flexbox) catch @panic("OOM");
    defer flexbox.element.release();
    popup.setChild(&flexbox.element);

    var stmt = (app.db.prepare_v2(
        \\SELECT ofx_accounts.id, ofx_accounts.hash, ofx_account_names.name
        \\FROM ofx_accounts
        \\LEFT JOIN ofx_account_names ON ofx_account_names.account_id = ofx_accounts.id
    , null) catch unreachable).?;
    defer stmt.finalize() catch unreachable;

    while ((stmt.step() catch unreachable) != .Done) {
        const account_id = stmt.columnInt64(0);
        const ofx_hash = stmt.columnText(1);
        const account_name = stmt.columnText(2);

        const row_text = std.fmt.allocPrint(app.gpa, "{?} | {?s} | {?s}", .{ account_id, account_name, ofx_hash }) catch @panic("OOM");

        const label = app.ui_manager.create(ui.Label) catch @panic("OOM");
        defer label.element.release();
        app.gpa.free(label.text);
        label.text = row_text;
        flexbox.appendChild(&label.element) catch @panic("OOM");
    }

    app.ui_manager.addPopup(&popup.element) catch @panic("OOM");
}

pub fn onLedgerBalancesButtonPressed(userdata: ?*anyopaque, _: *ui.Button) void {
    const app: *App = @ptrCast(@alignCast(userdata.?));

    const popup = app.ui_manager.create(ui.Popup) catch @panic("OOM");
    defer popup.element.release();
    popup.title = "OFX Accounts";
    popup.element.rect.size = .{ 400, 400 };

    const flexbox = app.ui_manager.create(ui.Flexbox) catch @panic("OOM");
    defer flexbox.element.release();
    popup.setChild(&flexbox.element);

    var stmt = (app.db.prepare_v2(
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
    , null) catch unreachable).?;
    defer stmt.finalize() catch {};
    while ((stmt.step() catch return) != .Done) {
        // TODO: sqlite3 fix `columnText` null pointer seg fault
        const day_posted = date_util.julianDayNumberToGregorianDate(@as(u64, @intCast(stmt.columnInt64(0))));
        const latest_balance_day = date_util.julianDayNumberToGregorianDate(@as(u64, @intCast(stmt.columnInt64(1))));
        const account_name = stmt.columnText(2);
        const ledger_balance = stmt.columnInt64(3);
        const running_balance = stmt.columnInt64(4);
        const currency_name = stmt.columnText(5);
        const currency_divisor = stmt.columnInt64(6);

        const difference = ledger_balance - running_balance;
        const row_text = std.fmt.allocPrint(app.gpa, "{?} | {?s} | {d}.{d} | {} | {d}.{d} | {?s} | {d}.{d}", .{
            day_posted.fmtISO(),
            account_name,
            @divTrunc(ledger_balance, currency_divisor),
            @as(u64, @intCast(@mod(ledger_balance, currency_divisor))),
            latest_balance_day.fmtISO(),
            @divTrunc(running_balance, currency_divisor),
            @as(u64, @intCast(@mod(running_balance, currency_divisor))),
            currency_name,
            @divTrunc(difference, currency_divisor),
            @as(u64, @intCast(@mod(difference, currency_divisor))),
        }) catch @panic("OOM");

        const label = app.ui_manager.create(ui.Label) catch @panic("OOM");
        defer label.element.release();
        app.gpa.free(label.text);
        label.text = row_text;
        label.color = if (difference == 0) [4]u8{ 0xFF, 0xFF, 0xFF, 0xFF } else [4]u8{ 0xFF, 0x00, 0x00, 0xFF };
        flexbox.appendChild(&label.element) catch @panic("OOM");
    }

    app.ui_manager.addPopup(&popup.element) catch @panic("OOM");
}

pub fn onOFXTransactionsButtonPressed(userdata: ?*anyopaque, _: *ui.Button) void {
    const app: *App = @ptrCast(@alignCast(userdata.?));

    const popup = app.ui_manager.create(ui.Popup) catch @panic("OOM");
    defer popup.element.release();
    popup.title = "OFX Accounts";
    popup.element.rect.size = .{ 400, 400 };

    const flexbox = app.ui_manager.create(ui.Flexbox) catch @panic("OOM");
    defer flexbox.element.release();
    popup.setChild(&flexbox.element);

    var stmt = (app.db.prepare_v2(
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
    , null) catch unreachable).?;
    defer stmt.finalize() catch {};
    while ((stmt.step() catch unreachable) != .Done) {
        const account_id = stmt.columnInt64(0);
        const id = stmt.columnInt64(1);
        const day_posted = date_util.julianDayNumberToGregorianDate(@as(u64, @intCast(stmt.columnInt64(2))));
        const account_hash = stmt.columnText(3);
        const amount = stmt.columnInt64(4);
        const currency_name = stmt.columnText(5);
        const currency_divisor = stmt.columnInt64(6);
        const description = stmt.columnText(7);

        const row_text = std.fmt.allocPrint(app.gpa, "{d} | {d} | {} | {?s} | {d}.{d} {?s} | {?s}", .{
            account_id,
            id,
            day_posted.fmtISO(),
            account_hash,
            @divTrunc(amount, currency_divisor),
            @as(u64, @intCast(@mod(amount, currency_divisor))),
            currency_name,
            description,
        }) catch unreachable;

        const label = app.ui_manager.create(ui.Label) catch @panic("OOM");
        defer label.element.release();
        app.gpa.free(label.text);
        label.text = row_text;
        flexbox.appendChild(&label.element) catch @panic("OOM");
    }

    app.ui_manager.addPopup(&popup.element) catch @panic("OOM");
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

    var framebuffer_size: [2]c_int = undefined;
    c.glfwGetFramebufferSize(app.window, &framebuffer_size[0], &framebuffer_size[1]);
    const framebuffer_sizef = [2]f32{
        @floatFromInt(framebuffer_size[0]),
        @floatFromInt(framebuffer_size[1]),
    };

    app.canvas.begin(.{
        .window_size = window_sizef,
        .framebuffer_size = framebuffer_sizef,
    });
    app.ui_manager.render(&app.canvas, window_sizef);
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

fn glfw_key_callback(window: ?*c.GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.C) void {
    const app = @as(*App, @ptrCast(@alignCast(c.glfwGetWindowUserPointer(window))));

    const key_event = ui.event.Key{
        .key = @enumFromInt(key),
        .scancode = scancode,
        .action = @enumFromInt(action),
        .mods = .{
            .shift = c.GLFW_MOD_SHIFT == c.GLFW_MOD_SHIFT & mods,
            .control = c.GLFW_MOD_CONTROL == c.GLFW_MOD_CONTROL & mods,
            .alt = c.GLFW_MOD_ALT == c.GLFW_MOD_ALT & mods,
            .super = c.GLFW_MOD_SUPER == c.GLFW_MOD_SUPER & mods,
            .caps_lock = c.GLFW_MOD_CAPS_LOCK == c.GLFW_MOD_CAPS_LOCK & mods,
            .num_lock = c.GLFW_MOD_NUM_LOCK == c.GLFW_MOD_NUM_LOCK & mods,
        },
    };

    if (app.ui_manager.onKey(key_event)) {
        return;
    }
}

fn glfw_mousebutton_callback(window: ?*c.GLFWwindow, button: c_int, action: c_int, mods: c_int) callconv(.C) void {
    _ = mods;
    const app = @as(*App, @ptrCast(@alignCast(c.glfwGetWindowUserPointer(window))));

    check_ui: {
        var mouse_pos_f64: [2]f64 = undefined;
        c.glfwGetCursorPos(window, &mouse_pos_f64[0], &mouse_pos_f64[1]);
        const mouse_pos = [2]f32{
            @floatCast(mouse_pos_f64[0]),
            @floatCast(mouse_pos_f64[1]),
        };

        const click_event = ui.event.Click{
            .pos = mouse_pos,
            .button = switch (button) {
                c.GLFW_MOUSE_BUTTON_LEFT => .left,
                c.GLFW_MOUSE_BUTTON_RIGHT => .right,
                c.GLFW_MOUSE_BUTTON_MIDDLE => .middle,
                else => break :check_ui,
            },
            .pressed = action == c.GLFW_PRESS,
        };

        if (app.ui_manager.onClick(click_event)) {
            return;
        }
    }
}

fn glfw_cursor_pos_callback(window: ?*c.GLFWwindow, xpos: f64, ypos: f64) callconv(.C) void {
    const app = @as(*App, @ptrCast(@alignCast(c.glfwGetWindowUserPointer(window))));

    const mouse_pos = [2]f32{ @floatCast(xpos), @floatCast(ypos) };

    if (app.ui_manager.onHover(mouse_pos)) {
        return;
    }
}

fn glfw_scroll_callback(window: ?*c.GLFWwindow, xoffset: f64, yoffset: f64) callconv(.C) void {
    const app = @as(*App, @ptrCast(@alignCast(c.glfwGetWindowUserPointer(window))));

    const scroll_event = ui.event.Scroll{
        .offset = [2]f32{
            @floatCast(xoffset),
            @floatCast(yoffset),
        },
    };

    if (app.ui_manager.onScroll(scroll_event)) {
        return;
    }
}

fn glfw_char_callback(window: ?*c.GLFWwindow, codepoint: c_uint) callconv(.C) void {
    const app = @as(*App, @alignCast(@ptrCast(c.glfwGetWindowUserPointer(window))));

    var text_input_event = ui.event.TextInput{ .text = .{} };
    const codepoint_len = std.unicode.utf8Encode(@as(u21, @intCast(codepoint)), &text_input_event.text.buffer) catch return;
    text_input_event.text.resize(codepoint_len) catch unreachable;

    if (app.ui_manager.onTextInput(text_input_event)) {
        return;
    }
}

fn glfw_window_size_callback(window: ?*c.GLFWwindow, width: c_int, height: c_int) callconv(.C) void {
    const app = @as(*App, @alignCast(@ptrCast(c.glfwGetWindowUserPointer(window))));
    _ = width;
    _ = height;
    app.ui_manager.needs_layout = true;
}

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
const date_util = @import("./date.zig");
const ui = @import("./ui.zig");
