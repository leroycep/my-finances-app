element: Element,
label: []const u8 = "checkbox",
value: bool = false,

userdata: ?*anyopaque = null,
on_change_fn: ?*const fn (?*anyopaque, *@This()) void = null,

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

const MARGIN = [2]f32{
    2,
    2,
};

pub fn layout(element: *Element, min_size: [2]f32, max_size: [2]f32) [2]f32 {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    _ = min_size;
    _ = max_size;
    const label_size = this.element.manager.font.textSize(this.label, 1);
    return .{
        this.element.manager.font.lineHeight + 2 * PADDING[1] + 2 * MARGIN[1] + label_size[0],
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
            canvas.font.lineHeight + 2 * PADDING[0],
            canvas.font.lineHeight + 2 * PADDING[1],
        },
        .color = [4]u8{ 0x60, 0x60, 0x60, 0xFF },
    });

    const color = if (this.value)
        [4]u8{ 0xFF, 0xFF, 0xFF, 0xFF }
    else
        [4]u8{ 0x00, 0x00, 0x00, 0xFF };
    canvas.rect(.{
        .pos = .{
            rect.pos[0] + MARGIN[0] + PADDING[0],
            rect.pos[1] + MARGIN[1] + PADDING[1],
        },
        .size = [2]f32{
            canvas.font.lineHeight,
            canvas.font.lineHeight,
        },
        .color = color,
    });

    _ = canvas.writeText(this.label, .{
        .pos = .{
            rect.pos[0] + canvas.font.lineHeight + 2 * MARGIN[0] + 2 * PADDING[0],
            rect.pos[1] + MARGIN[1] + PADDING[1],
        },
        .baseline = .top,
        .@"align" = .left,
        .color = [4]u8{ 0xFF, 0xFF, 0xFF, 0xFF },
    });
}

fn onClick(element: *Element, event: ui.event.Click) bool {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    if (!event.pressed and event.button == .left and this.element.manager.pointer_capture_element == &this.element) {
        this.element.manager.pointer_capture_element = null;
    }
    if (!event.pressed or event.button != .left) return false;

    this.value = !this.value;
    if (this.on_change_fn) |on_change| {
        on_change(this.userdata, this);
    }

    return true;
}

const Rect = ui.Rect;
const Element = ui.Element;
const ui = @import("../ui.zig");
const Canvas = @import("../Canvas.zig");
const utils = @import("utils");
const std = @import("std");
