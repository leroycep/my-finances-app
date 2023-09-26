element: Element,
text: []const u8 = "Button",

userdata: ?*anyopaque = null,
on_click_fn: ?*const fn (?*anyopaque, *@This()) void = null,

const INTERFACE = Element.Interface{
    .destroy_fn = destroy,
    .layout_fn = layout,
    .render_fn = render,
    .on_click_fn = onClick,
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
    this.element.manager.gpa.destroy(this);
}

const PADDING = [2]f32{
    2,
    2,
};

pub fn layout(element: *Element, min_size: [2]f32, max_size: [2]f32) [2]f32 {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    _ = min_size;
    _ = max_size;
    const text_size = this.element.manager.font.textSize(this.text, 1);
    return .{
        text_size[0] + 2 * PADDING[0],
        text_size[1] + 2 * PADDING[1],
    };
}

fn render(element: *Element, canvas: *Canvas, rect: Rect) void {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);

    const is_hovered = this.element.manager.hovered_element == &this.element;
    const rect_color = if (is_hovered) [4]u8{ 0x50, 0x50, 0x50, 0xFF } else [4]u8{ 0x30, 0x30, 0x30, 0xFF };
    const text_color = if (is_hovered) [4]u8{ 0xFF, 0xFF, 0x00, 0xFF } else [4]u8{ 0xFF, 0xFF, 0xFF, 0xFF };

    canvas.rect(.{
        .pos = rect.pos,
        .size = rect.size,
        .color = rect_color,
    });

    _ = canvas.writeText(this.text, .{
        .pos = .{
            rect.pos[0] + PADDING[0],
            rect.pos[1] + PADDING[1],
        },
        .baseline = .top,
        .color = text_color,
    });
}

fn onClick(element: *Element, event: ui.event.Click) bool {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    if (!event.pressed or event.button != .left) return false;

    if (this.on_click_fn) |on_click_fn| {
        on_click_fn(this.userdata, this);
    }

    return true;
}

const Rect = ui.Rect;
const Element = ui.Element;
const ui = @import("../ui.zig");
const Canvas = @import("../Canvas.zig");
const utils = @import("utils");
const std = @import("std");
