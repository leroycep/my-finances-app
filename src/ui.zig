pub const Trifold = @import("./ui/Trifold.zig");
pub const Menu = @import("./ui/Menu.zig");
pub const TabList = @import("./ui/TabList.zig");
pub const PanZoom = @import("./ui/PanZoom.zig");
pub const Popup = @import("./ui/Popup.zig");
pub const TextField = @import("./ui/TextField.zig");
pub const NumberField = @import("./ui/NumberField.zig");
pub const form = @import("./ui/form.zig");
pub const Button = @import("./ui/Button.zig");
pub const Flexbox = @import("./ui/Flexbox.zig");
pub const FileSelect = @import("./ui/FileSelect.zig");
pub const Plot = @import("./ui/Plot.zig");
pub const Slider = @import("./ui/Slider.zig");
pub const ProgressBar = @import("./ui/ProgressBar.zig");
pub const CheckBox = @import("./ui/CheckBox.zig");
pub const Label = @import("./ui/Label.zig");

pub const Rect = struct {
    pos: [2]f32,
    size: [2]f32,

    pub fn contains(this: @This(), point: [2]f32) bool {
        return point[0] >= this.pos[0] and
            point[1] >= this.pos[1] and
            point[0] <= this.pos[0] + this.size[0] and
            point[1] <= this.pos[1] + this.size[1];
    }
};

pub const Manager = struct {
    gpa: std.mem.Allocator,
    font: *const BitmapFont,

    root: ?*Element = null,
    popups: std.AutoArrayHashMapUnmanaged(*Element, void) = .{},

    focused_element: ?*Element = null,
    hovered_element: ?*Element = null,
    pointer_capture_element: ?*Element = null,

    needs_layout: bool = true,
    cursor_shape: ?CursorShape = null,

    pub const Popup = struct {
        rect: Rect,
        title: []const u8,
    };

    pub fn deinit(this: *@This()) void {
        if (this.root) |r| {
            r.release();
        }
        for (this.popups.keys()) |popup| {
            popup.release();
        }
        this.popups.deinit(this.gpa);
    }

    pub fn create(this: *@This(), comptime E: type) !*E {
        std.debug.assert(std.meta.trait.hasField("element")(E));
        std.debug.assert(std.meta.trait.hasFn("init")(E));

        // TODO: Track all created Elements
        const e = try this.gpa.create(E);
        try E.init(&e.element, this);
        e.element.acquire();
        return e;
    }

    pub fn setRoot(this: *@This(), new_root_opt: ?*Element) void {
        if (new_root_opt) |new_root| {
            new_root.acquire();
        }
        if (this.root) |r| {
            r.release();
        }
        if (new_root_opt) |new_root| {
            new_root.parent = null;
        }
        this.root = new_root_opt;
    }

    pub fn addPopup(this: *@This(), popup: *Element) !void {
        const gop = try this.popups.getOrPut(this.gpa, popup);
        if (!gop.found_existing) {
            popup.acquire();
            popup.parent = null;
            this.needs_layout = true;
        }
    }

    pub fn removePopup(this: *@This(), popup: *Element) bool {
        if (this.popups.swapRemove(popup)) {
            popup.release();
            return true;
        }
        return false;
    }

    pub fn render(this: *Manager, canvas: *Canvas, window_size: [2]f32) void {
        if (this.needs_layout) {
            if (this.root) |r| r.rect.size = r.layout(.{ 0, 0 }, window_size);
            for (this.popups.keys()) |popup| {
                popup.rect.size = popup.layout(.{ 0, 0 }, window_size);
            }
            this.needs_layout = false;
        }

        if (this.root) |r| {
            r.render(canvas, r.rect);
        }
        for (this.popups.keys()) |popup| {
            popup.render(canvas, popup.rect);
        }
    }

    pub fn onHover(this: *Manager, pos: [2]f32) bool {
        this.cursor_shape = null;
        this.hovered_element = null;
        if (this.pointer_capture_element) |pce| {
            const transform = pce.getTransform();
            const transformed_pos = utils.mat4.mulVec(f32, transform, .{
                pos[0],
                pos[1],
                0,
                1,
            })[0..2].*;

            if (pce.onHover(transformed_pos)) |hovered| {
                this.hovered_element = hovered;
                return true;
            }
        }
        for (0..this.popups.keys().len) |i| {
            const popup = this.popups.keys()[this.popups.keys().len - 1 - i];
            if (popup.rect.contains(pos)) {
                if (popup.onHover(.{
                    pos[0] - popup.rect.pos[0],
                    pos[1] - popup.rect.pos[1],
                })) |hovered| {
                    this.hovered_element = hovered;
                    return true;
                }
            }
        }
        if (this.root) |r| {
            if (r.onHover(pos)) |hovered| {
                this.hovered_element = hovered;
                return true;
            }
        }
        return false;
    }

    pub fn onClick(this: *Manager, e: event.Click) bool {
        if (e.pressed and e.button == .left) this.focused_element = null;
        if (this.pointer_capture_element) |pce| {
            const transform = pce.getTransform();
            const transformed_pos = utils.mat4.mulVec(f32, transform, .{
                e.pos[0],
                e.pos[1],
                0,
                1,
            })[0..2].*;
            const transformed_event = event.Click{
                .pos = transformed_pos,
                .button = e.button,
                .pressed = e.pressed,
            };

            if (pce.onClick(transformed_event)) {
                return true;
            }
        }
        for (0..this.popups.keys().len) |i| {
            const popup = this.popups.keys()[this.popups.keys().len - 1 - i];
            if (popup.rect.contains(e.pos)) {
                if (popup.onClick(e.translate(.{
                    -popup.rect.pos[0],
                    -popup.rect.pos[1],
                }))) {
                    if (this.popups.orderedRemove(popup)) {
                        this.popups.putAssumeCapacity(popup, {});
                    }
                    return true;
                }
            }
        }
        if (this.root) |r| {
            return r.onClick(e);
        }
        return false;
    }

    pub fn onScroll(this: *Manager, e: event.Scroll) bool {
        if (this.pointer_capture_element) |pce| {
            if (pce.onScroll(e)) {
                return true;
            }
        }
        if (this.hovered_element) |hovered| {
            if (hovered.onScroll(e)) {
                return true;
            }
        }
        return false;
    }

    pub fn onTextInput(this: *Manager, e: event.TextInput) bool {
        if (this.focused_element) |focused| {
            if (focused.onTextInput(e)) {
                return true;
            }
        }
        return false;
    }

    pub fn onKey(this: *Manager, e: event.Key) bool {
        if (this.focused_element) |focused| {
            if (focused.onKey(e)) {
                return true;
            }
        }
        return false;
    }
};

pub const event = struct {
    pub const Hover = struct {
        pos: [2]f32,
        buttons: struct {
            left: bool,
            right: bool,
            middle: bool,
        },
    };

    pub const Click = struct {
        pos: [2]f32,
        button: enum {
            left,
            right,
            middle,
        },
        pressed: bool,

        pub fn translate(this: @This(), offset: [2]f32) @This() {
            return @This(){
                .pos = .{ this.pos[0] + offset[0], this.pos[1] + offset[1] },
                .button = this.button,
                .pressed = this.pressed,
            };
        }
    };

    pub const Scroll = struct {
        offset: [2]f32,
    };

    pub const TextInput = struct {
        text: std.BoundedArray(u8, 16),
    };

    // TODO: Make all of these fields enums; remove dependence on GLFW
    pub const Key = struct {
        key: enum(c_int) {
            up = c.GLFW_KEY_UP,
            left = c.GLFW_KEY_LEFT,
            right = c.GLFW_KEY_RIGHT,
            down = c.GLFW_KEY_DOWN,
            page_up = c.GLFW_KEY_PAGE_UP,
            page_down = c.GLFW_KEY_PAGE_DOWN,
            enter = c.GLFW_KEY_ENTER,
            backspace = c.GLFW_KEY_BACKSPACE,
            delete = c.GLFW_KEY_DELETE,
            _,
        },
        scancode: c_int,
        action: enum(c_int) {
            press = c.GLFW_PRESS,
            repeat = c.GLFW_REPEAT,
            release = c.GLFW_RELEASE,
        },
        mods: packed struct {
            shift: bool,
            control: bool,
            alt: bool,
            super: bool,
            caps_lock: bool,
            num_lock: bool,
        },
    };
};

pub const Element = struct {
    interface: *const Interface,
    manager: *Manager,
    reference_count: usize = 0,
    parent: ?*Element = null,
    rect: Rect = .{ .pos = .{ 0, 0 }, .size = .{ 0, 0 } },

    pub const Interface = struct {
        destroy_fn: *const fn (*Element) void,
        layout_fn: *const fn (*Element, min_size: [2]f32, max_size: [2]f32) [2]f32,
        render_fn: *const fn (*Element, *Canvas, Rect) void,
        on_hover_fn: *const fn (*Element, pos: [2]f32) ?*Element = onHoverDefault,
        on_click_fn: *const fn (*Element, event.Click) bool = onClickDefault,
        on_scroll_fn: *const fn (*Element, event.Scroll) bool = onScrollDefault,
        on_text_input_fn: *const fn (*Element, event.TextInput) bool = onTextInputDefault,
        on_key_fn: *const fn (*Element, event.Key) bool = onKeyDefault,
        get_transform_fn: *const fn (*Element) [4][4]f32 = getTransformDefault,
    };

    pub fn acquire(element: *Element) void {
        element.reference_count += 1;
    }

    pub fn release(element: *Element) void {
        element.reference_count -= 1;
        if (element.reference_count == 0) {
            element.destroy();
        }
    }

    pub fn destroy(element: *Element) void {
        if (element.manager.pointer_capture_element == element) {
            element.manager.pointer_capture_element = null;
        }
        return element.interface.destroy_fn(element);
    }

    pub fn layout(element: *Element, min_size: [2]f32, max_size: [2]f32) [2]f32 {
        return element.interface.layout_fn(element, min_size, max_size);
    }

    pub fn render(element: *Element, canvas: *Canvas, rect: Rect) void {
        return element.interface.render_fn(element, canvas, rect);
    }

    pub fn onHover(element: *Element, pos: [2]f32) ?*Element {
        return element.interface.on_hover_fn(element, pos);
    }

    pub fn onClick(element: *Element, e: event.Click) bool {
        return element.interface.on_click_fn(element, e);
    }

    pub fn onScroll(element: *Element, e: event.Scroll) bool {
        return element.interface.on_scroll_fn(element, e);
    }

    pub fn onTextInput(element: *Element, e: event.TextInput) bool {
        return element.interface.on_text_input_fn(element, e);
    }

    pub fn onKey(element: *Element, e: event.Key) bool {
        return element.interface.on_key_fn(element, e);
    }

    pub fn getTransform(element: *Element) [4][4]f32 {
        return element.interface.get_transform_fn(element);
    }

    // Default functions

    pub fn onHoverDefault(element: *Element, pos: [2]f32) ?*Element {
        _ = pos;
        return element;
    }

    pub fn onClickDefault(element: *Element, e: event.Click) bool {
        _ = element;
        _ = e;
        return false;
    }

    pub fn onScrollDefault(element: *Element, e: event.Scroll) bool {
        _ = element;
        _ = e;
        return false;
    }

    pub fn onTextInputDefault(this: *Element, e: event.TextInput) bool {
        _ = this;
        _ = e;
        return false;
    }

    pub fn onKeyDefault(this: *Element, e: event.Key) bool {
        _ = this;
        _ = e;
        return false;
    }

    pub fn getTransformDefault(this: *Element) [4][4]f32 {
        const local = utils.mat4.translate(f32, .{ -this.rect.pos[0], -this.rect.pos[1], 0 });
        if (this.parent) |parent| {
            return utils.mat4.mul(f32, local, parent.getTransform());
        } else {
            return local;
        }
    }
};

pub const CursorShape = enum {
    horizontal_resize,
    vertical_resize,
    sw_to_ne_resize,
    nw_to_se_resize,
};

const std = @import("std");
const utils = @import("utils");
pub const c = @import("./c.zig");
const BitmapFont = @import("./Canvas/bitmap.zig").Font;
const Canvas = @import("./Canvas.zig");
