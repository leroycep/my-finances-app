element: Element,
min: f32 = 0,
max: f32 = 1,
step: f32 = 0.1,
number: f32 = 0,
axis_type: AxisType = .linear,

userdata: ?*anyopaque = null,
on_change_fn: ?*const fn (?*anyopaque, *@This()) void = null,

pub const AxisType = enum {
    linear,
    log,
};

const INTERFACE = Element.Interface{
    .destroy_fn = destroy,
    .layout_fn = layout,
    .render_fn = render,
    .on_hover_fn = onHover,
    .on_click_fn = onClick,
    .on_scroll_fn = onScroll,
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
    // const text_size = this.element.manager.font.fmtTextSize("{d}", .{this.number}, 1);
    return .{
        max_size[0],
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

    const percentage = switch (this.axis_type) {
        .linear => (this.number - this.min) / (this.max - this.min),
        .log => (@log(this.number) - @log(this.min)) / (@log(this.max) - @log(this.min)),
    };
    const slider_pos = percentage * (rect.size[0] - 2 * MARGIN[0] - 2 * PADDING[0]);
    canvas.rect(.{
        .pos = .{ rect.pos[0] + slider_pos - 3 + MARGIN[0] + PADDING[0], rect.pos[1] + MARGIN[1] + PADDING[1] },
        .size = .{ 6, rect.size[1] - 2 * MARGIN[1] - 2 * PADDING[1] },
        .color = .{ 0xFF, 0xFF, 0xFF, 0xAA },
    });

    canvas.printText("{d}", .{this.number}, .{
        .pos = .{
            rect.pos[0] + this.element.rect.size[0] - MARGIN[0] - PADDING[0],
            rect.pos[1] + MARGIN[1] + PADDING[1],
        },
        .baseline = .top,
        .@"align" = .right,
    });
}

fn onHover(element: *Element, pos: [2]f32) ?*Element {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    if (this.element.manager.pointer_capture_element == &this.element) {
        const percentage = std.math.clamp((pos[0] - MARGIN[0] - PADDING[0]) / (this.element.rect.size[0] - 2 * MARGIN[0] - 2 * PADDING[0]), 0, 1);
        const new_number = switch (this.axis_type) {
            .linear => percentage * (this.max - this.min) + this.min,
            .log => @exp(percentage * (@log(this.max) - @log(this.min)) + @log(this.min)),
        };
        this.number = @floor(new_number);
        if (this.on_change_fn) |on_change| {
            on_change(this.userdata, this);
        }
    }
    return &this.element;
}

fn onClick(element: *Element, event: ui.event.Click) bool {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    if (!event.pressed and event.button == .left and this.element.manager.pointer_capture_element == &this.element) {
        this.element.manager.pointer_capture_element = null;
    }
    if (!event.pressed or event.button != .left) return false;

    this.element.manager.pointer_capture_element = &this.element;

    const percentage = std.math.clamp((event.pos[0] - MARGIN[0] - PADDING[0]) / (this.element.rect.size[0] - 2 * MARGIN[0] - 2 * PADDING[0]), 0, 1);
    const new_number = switch (this.axis_type) {
        .linear => percentage * (this.max - this.min) + this.min,
        .log => @exp(percentage * (@log(this.max) - @log(this.min)) + @log(this.min)),
    };
    this.number = @floor(new_number);
    if (this.on_change_fn) |on_change| {
        on_change(this.userdata, this);
    }

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

const bitmap_font = @import("../Canvas/bitmap.zig");
const Rect = ui.Rect;
const Element = ui.Element;
const ui = @import("../ui.zig");
const Canvas = @import("../Canvas.zig");
const utils = @import("utils");
const std = @import("std");
