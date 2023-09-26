element: Element,
number: f32 = 0,
current_input_value: ?f32 = null,

userdata: ?*anyopaque = null,
on_change_fn: ?*const fn (?*anyopaque, *@This()) void = null,

const INTERFACE = Element.Interface{
    .destroy_fn = destroy,
    .layout_fn = layout,
    .render_fn = render,
    .on_click_fn = onClick,
    .on_scroll_fn = onScroll,
    .on_text_input_fn = onTextInput,
    .on_key_fn = onKey,
};

pub fn init(element: *Element, manager: *ui.Manager) !void {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    this.* = .{
        .element = .{
            .manager = manager,
            .interface = &INTERFACE,
        },
    };
}

pub fn destroy(element: *Element) void {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    this.number = 0;
    this.element.manager.gpa.destroy(this);
}

const PADDING = [2]f32{
    2,
    2,
};

const MARGIN = [2]f32{
    2,
    2,
};

pub fn layout(element: *Element, min_size: [2]f32, max_size: [2]f32) [2]f32 {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    _ = min_size;
    _ = max_size;
    const text_size = this.element.manager.font.textSize("99999999", 1);
    return .{
        text_size[0],
        this.element.manager.font.lineHeight + 2 * PADDING[1] + 2 * MARGIN[1],
    };
}

fn render(element: *Element, canvas: *Canvas, rect: Rect) void {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);

    canvas.rect(.{
        .pos = .{
            rect.pos[0] + MARGIN[0],
            rect.pos[1] + MARGIN[1],
        },
        .size = [2]f32{
            this.element.rect.size[0] - 2 * MARGIN[0],
            canvas.font.lineHeight + 2 * PADDING[1],
        },
        .color = [4]u8{ 0x60, 0x60, 0x60, 0xFF },
    });

    if (this.element.manager.focused_element != &this.element) {
        this.current_input_value = null;
    }

    const value = this.current_input_value orelse this.number;

    const text_size = this.element.manager.font.fmtTextSize("{d}", .{value}, 1);

    canvas.printText("{d}", .{value}, .{
        .pos = .{
            rect.pos[0] + this.element.rect.size[0] - MARGIN[0] - PADDING[0],
            rect.pos[1] + MARGIN[1] + PADDING[1],
        },
        .baseline = .top,
        .@"align" = .right,
    });
    if (this.element.manager.focused_element == &this.element) {
        canvas.rect(.{
            .pos = .{
                rect.pos[0] + this.element.rect.size[0] - MARGIN[0] - PADDING[0] - text_size[0],
                rect.pos[1] + MARGIN[1] + PADDING[1],
            },
            .size = text_size,
            .color = .{ 0xFF, 0xFF, 0xFF, 0xAA },
        });
    }
}

fn onClick(element: *Element, event: ui.event.Click) bool {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    if (event.pressed and event.button != .left) this.current_input_value = null;
    if (!event.pressed or event.button != .left) return false;

    this.element.manager.focused_element = &this.element;

    return true;
}

fn onScroll(element: *Element, event: ui.event.Scroll) bool {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);

    const sign = std.math.sign(event.offset[1]);
    const rounded = @ceil(@fabs(event.offset[1]));
    this.number += sign * rounded;
    this.element.manager.focused_element = &this.element;

    if (this.on_change_fn) |on_change| {
        on_change(this.userdata, this);
    }

    return true;
}

fn onTextInput(element: *Element, event: ui.event.TextInput) bool {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);

    // Delete any text that is currently selected
    var new_number = this.current_input_value orelse 0;

    // Append new text
    var digits_added: f32 = 1;
    var new_digits: f32 = 0;
    for (event.text.slice()) |c| {
        if (std.ascii.isDigit(c)) {
            digits_added *= 10;
            new_digits += @floatFromInt(c - '0');
        } else {
            return false;
        }
    }

    new_number *= digits_added;
    new_number += new_digits;

    this.current_input_value = new_number;
    this.number = new_number;

    if (this.on_change_fn) |on_change| {
        on_change(this.userdata, this);
    }

    return true;
}

fn onKey(element: *Element, event: ui.event.Key) bool {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    switch (event.key) {
        .enter => if (event.action == .press or event.action == .repeat) {
            if (this.current_input_value) |*current_value| {
                this.number = current_value.*;
                this.current_input_value = null;
                this.element.manager.focused_element = null;
                if (this.on_change_fn) |on_change| {
                    on_change(this.userdata, this);
                }
            }
        },
        .backspace => if (event.action == .press or event.action == .repeat) {
            if (this.current_input_value) |*current_value| {
                current_value.* = @floor(this.number / 10);
                this.number = current_value.*;
                if (this.on_change_fn) |on_change| {
                    on_change(this.userdata, this);
                }
            }
        },
        .delete => if (event.action == .press or event.action == .repeat) {
            if (this.current_input_value) |*current_value| {
                current_value.* = 0;
                this.number = current_value.*;
                if (this.on_change_fn) |on_change| {
                    on_change(this.userdata, this);
                }
            }
        },
        .up => if (event.action == .press or event.action == .repeat) {
            this.number += 1;
            if (this.on_change_fn) |on_change| {
                on_change(this.userdata, this);
            }
        },
        .down => if (event.action == .press or event.action == .repeat) {
            this.number -= 1;
            if (this.on_change_fn) |on_change| {
                on_change(this.userdata, this);
            }
        },
        else => {},
    }
    return true;
}

const Rect = ui.Rect;
const Element = ui.Element;
const ui = @import("../ui.zig");
const Canvas = @import("../Canvas.zig");
const utils = @import("utils");
const std = @import("std");
