element: Element,
items: []const Item = &.{},
rects: std.ArrayListUnmanaged(Rect) = .{},
hovered: ?usize = null,
userdata: ?*anyopaque = null,

pub const Item = struct {
    name: []const u8,
    callback: *const fn (?*anyopaque) void,
};

const INTERFACE = Element.Interface{
    .destroy_fn = destroy,
    .layout_fn = layout,
    .render_fn = render,
    .on_hover_fn = onHover,
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
    this.rects.deinit(this.element.manager.gpa);
    this.element.manager.gpa.destroy(this);
}

pub fn layout(element: *Element, min_size: [2]f32, max_size: [2]f32) [2]f32 {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    this.rects.resize(this.element.manager.gpa, this.items.len) catch @panic("OOM");

    for (this.items, this.rects.items) |menu_item, *rect| {
        rect.size = this.element.manager.font.textSize(menu_item.name, 1);
    }

    const margin = [2]f32{ 10, 0.25 * this.element.manager.font.lineHeight };
    const start_pos = [2]f32{
        0,
        0,
    };
    var pos = start_pos;
    for (this.rects.items) |*rect| {
        if (pos[0] + margin[0] + rect.size[0] > max_size[0] and pos[0] != start_pos[0]) {
            pos[0] = start_pos[0];
            pos[1] += this.element.manager.font.lineHeight + 2 * margin[1];
        }
        rect.pos = .{
            pos[0] + margin[0],
            pos[1] + margin[1],
        };
        pos[0] += rect.size[0] + 2 * margin[0];
    }

    return .{ max_size[0], @max(min_size[1], pos[1] + this.element.manager.font.lineHeight + 2 * margin[1]) };
}

fn render(element: *Element, canvas: *Canvas, rect: Rect) void {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);

    const is_hovered = this.element.manager.hovered_element == &this.element;
    // set hovered_index to rects.len if nothing is hovered, so that i in the loop below is never equal to hovered_index
    const hovered_index = if (this.hovered) |h| h else this.rects.items.len;

    for (this.items, this.rects.items, 0..) |item, item_rect, i| {
        const color = if (is_hovered and hovered_index == i) [4]u8{ 0x00, 0xFF, 0xFF, 0xFF } else [4]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
        canvas.writeText(item.name, .{
            .pos = .{ rect.pos[0] + item_rect.pos[0], rect.pos[1] + item_rect.pos[1] },
            .baseline = .top,
            .color = color,
        });
    }
}

fn onHover(element: *Element, pos: [2]f32) ?*Element {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    this.hovered = null;
    for (this.rects.items, 0..) |rect, i| {
        if (rect.contains(pos)) {
            this.hovered = i;
            this.element.manager.hovered_element = &this.element;
        }
    }
    return &this.element;
}

fn onClick(element: *Element, event: ui.event.Click) bool {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);

    if (!event.pressed or event.button != .left) return false;

    for (this.rects.items, this.items) |rect, item| {
        if (rect.contains(event.pos)) {
            item.callback(this.userdata);
            return true;
        }
    }
    return false;
}

const Rect = ui.Rect;
const Element = ui.Element;
const ui = @import("../ui.zig");
const Canvas = @import("../Canvas.zig");
const std = @import("std");
