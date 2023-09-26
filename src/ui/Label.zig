element: Element,
text: []u8,
color: [4]u8 = .{ 0xFF, 0xFF, 0xFF, 0xFF },

const INTERFACE = Element.Interface{
    .destroy_fn = destroy,
    .layout_fn = layout,
    .render_fn = render,
};

pub fn init(element: *Element, manager: *ui.Manager) !void {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    const text = try manager.gpa.dupe(u8, "Label");
    this.* = .{
        .element = .{
            .manager = manager,
            .interface = &INTERFACE,
        },
        .text = text,
    };
}

pub fn destroy(element: *Element) void {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    this.element.manager.gpa.free(this.text);
    this.element.manager.gpa.destroy(this);
}

pub fn setText(this: *@This(), text: []const u8) !void {
    const text_cloned = try this.element.manager.gpa.dupe(u8, text);
    this.element.manager.gpa.free(this.text);
    this.text = text_cloned;
}

const PADDING = [2]f32{
    2,
    2,
};

pub fn layout(element: *Element, min_size: [2]f32, max_size: [2]f32) [2]f32 {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    const text_size = this.element.manager.font.textSize(this.text, 1);
    return .{
        std.math.clamp(text_size[0] + 2 * PADDING[0], min_size[0], max_size[0]),
        std.math.clamp(text_size[1] + 2 * PADDING[1], min_size[1], max_size[1]),
    };
}

fn render(element: *Element, canvas: *Canvas, rect: Rect) void {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);

    _ = canvas.writeText(this.text, .{
        .pos = .{
            rect.pos[0] + PADDING[0],
            rect.pos[1] + PADDING[1],
        },
        .baseline = .top,
        .color = this.color,
    });
}

const Rect = ui.Rect;
const Element = ui.Element;
const ui = @import("../ui.zig");
const Canvas = @import("../Canvas.zig");
const utils = @import("utils");
const std = @import("std");
