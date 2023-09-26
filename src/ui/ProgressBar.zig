element: Element,
progress: f32 = 0,
color: [4]u8 = .{ 0xFF, 0xFF, 0xFF, 0xFF },

const INTERFACE = Element.Interface{
    .destroy_fn = deinit,
    .layout_fn = layout,
    .render_fn = render,
};

pub fn deinit(element: *Element) void {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    this.element.manager.gpa.destroy(this);
}

pub fn init(element: *Element, manager: *ui.Manager) !void {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    this.* = .{
        .element = .{
            .manager = manager,
            .interface = &INTERFACE,
        },
    };
}

pub fn layout(element: *Element, min_size: [2]f32, max_size: [2]f32) [2]f32 {
    _ = min_size;
    _ = max_size[0];
    return .{ 100, element.manager.font.lineHeight * 1.5 };
}

fn render(element: *Element, canvas: *Canvas, rect: Rect) void {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);

    const width = rect.size[0] * this.progress;
    canvas.rect(.{
        .pos = rect.pos,
        .size = [2]f32{
            width,
            rect.size[1],
        },
        .color = this.color,
    });

    const midpoint = [2]f32{
        rect.pos[0] + rect.size[0] / 2,
        rect.pos[1] + rect.size[1] / 2,
    };

    canvas.flush();
    gl.blendFunc(gl.ONE_MINUS_DST_COLOR, gl.ZERO);
    defer {
        canvas.flush();
        gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    }

    canvas.printText("{d:0.1}%", .{this.progress * 100}, .{
        .pos = midpoint,
        .baseline = .middle,
        .@"align" = .center,
    });
}

const Rect = ui.Rect;
const Element = ui.Element;
const gl = @import("gl");
const ui = @import("../ui.zig");
const Canvas = @import("../Canvas.zig");
const utils = @import("utils");
const std = @import("std");
