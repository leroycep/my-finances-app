element: Element,
tab_names: []const []const u8 = &.{},
rects: std.ArrayListUnmanaged(Rect) = .{},
selected: usize = 0,
hovered: ?usize = null,

userdata: ?*anyopaque = null,
on_select_fn: ?SelectCallback = null,

const INTERFACE = Element.Interface{
    .destroy_fn = destroy,
    .layout_fn = layout,
    .render_fn = render,
    .on_hover_fn = onHover,
    .on_click_fn = onClick,
};

const TabList = @This();

const SelectCallback = *const fn (?*anyopaque, *TabList) void;

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
    this.rects.resize(this.element.manager.gpa, this.tab_names.len) catch @panic("OOM");

    _ = min_size;

    var max_width: f32 = 0;
    var pos = [2]f32{
        4,
        4,
    };
    for (this.tab_names, this.rects.items) |name, *rect| {
        rect.pos = pos;
        rect.size = this.element.manager.font.textSize(name, 1);
        max_width = @max(max_width, rect.size[0]);
        pos[1] += this.element.manager.font.lineHeight * 1.5;
    }

    return .{ max_width + 8, max_size[1] };
}

fn render(element: *Element, canvas: *Canvas, rect: Rect) void {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);

    const is_hovered = this.element.manager.hovered_element == &this.element;
    // set hovered_index to rects.len if nothing is hovered, so that i in the loop below is never equal to hovered_index
    const hovered_index = if (this.hovered) |h| h else this.rects.items.len;

    for (this.tab_names, this.rects.items, 0..) |name, name_rect, i| {
        const color = if (is_hovered and hovered_index == i)
            [4]u8{ 0xFF, 0xFF, 0x00, 0xFF }
        else if (this.selected == i)
            [4]u8{ 0xFF, 0xFF, 0xFF, 0xFF }
        else
            [4]u8{ 0xBB, 0xBB, 0xBB, 0xFF };

        canvas.writeText(name, .{
            .pos = .{ rect.pos[0] + name_rect.pos[0], rect.pos[1] + name_rect.pos[1] },
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
            return &this.element;
        }
    }
    return null;
}

fn onClick(element: *Element, event: ui.event.Click) bool {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);

    if (!event.pressed or event.button != .left) return false;

    for (this.rects.items, 0..) |rect, i| {
        if (rect.contains(event.pos)) {
            this.setSelected(i);
            return true;
        }
    }
    return false;
}

pub fn setSelected(this: *@This(), selection: usize) void {
    std.debug.assert(selection < this.tab_names.len);

    this.selected = selection;
    if (this.on_select_fn) |on_select_fn| {
        on_select_fn(this.userdata, this);
    }
}

const Rect = ui.Rect;
const Element = ui.Element;
const ui = @import("../ui.zig");
const Canvas = @import("../Canvas.zig");
const std = @import("std");
