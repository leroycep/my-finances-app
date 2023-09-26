element: Element,
children: std.ArrayListUnmanaged(*Element) = .{},
direction: Direction = .col,
justification: Justification = .start,
cross_align: CrossAlign = .start,

const INTERFACE = Element.Interface{
    .destroy_fn = destroy,
    .layout_fn = layout,
    .render_fn = render,
    .on_hover_fn = onHover,
    .on_click_fn = onClick,
};

pub const Direction = enum {
    row,
    col,
};

pub const Justification = enum {
    start,
    space_between,
    end,
};

pub const CrossAlign = enum {
    start,
    center,
    end,
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
    for (this.children.items) |child| {
        child.release();
    }
    this.children.deinit(this.element.manager.gpa);
    this.element.manager.gpa.destroy(this);
}

pub fn appendChild(this: *@This(), child: *Element) !void {
    try this.children.append(this.element.manager.gpa, child);
    child.acquire();
    child.parent = &this.element;
}

pub fn layout(element: *Element, min_size: [2]f32, max_size: [2]f32) [2]f32 {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);

    const main_axis: usize = switch (this.direction) {
        .row => 0,
        .col => 1,
    };
    const cross_axis: usize = switch (this.direction) {
        .row => 1,
        .col => 0,
    };

    var main_space_used: f32 = 0;
    var cross_min_width: f32 = min_size[cross_axis];

    for (this.children.items) |child| {
        var constraint_min: [2]f32 = undefined;
        var constraint_max: [2]f32 = undefined;

        constraint_min[main_axis] = 0;
        constraint_min[cross_axis] = cross_min_width;

        constraint_max[main_axis] = max_size[main_axis] - main_space_used;
        constraint_max[cross_axis] = max_size[cross_axis];

        child.rect.size = child.layout(constraint_min, constraint_max);

        main_space_used += child.rect.size[main_axis];
        cross_min_width = @max(cross_min_width, child.rect.size[cross_axis]);
    }

    const num_items: f32 = @floatFromInt(this.children.items.len);

    const space_before: f32 = switch (this.justification) {
        .start, .space_between => 0,
        .end => max_size[main_axis] - main_space_used,
    };
    const space_between: f32 = switch (this.justification) {
        .start, .end => 0,
        .space_between => (max_size[main_axis] - main_space_used) / @max(num_items - 1, 1),
    };
    const space_after: f32 = switch (this.justification) {
        .start => max_size[main_axis] - main_space_used,
        .space_between, .end => 0,
    };
    _ = space_after;

    var main_pos: f32 = 0;
    main_pos += space_before;

    for (this.children.items) |child| {
        child.rect.pos[main_axis] = main_pos;

        child.rect.pos[cross_axis] = switch (this.cross_align) {
            .start => 0,
            .center => cross_min_width / 2 - child.rect.size[cross_axis] / 2,
            .end => cross_min_width - child.rect.size[cross_axis],
        };

        main_pos += child.rect.size[main_axis] + space_between;
    }

    var bounds = [2]f32{ 0, 0 };
    bounds[main_axis] = max_size[main_axis];
    bounds[cross_axis] = cross_min_width;
    return bounds;
}

fn render(element: *Element, canvas: *Canvas, rect: Rect) void {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);

    for (this.children.items) |child| {
        child.render(canvas, .{
            .pos = .{
                rect.pos[0] + child.rect.pos[0],
                rect.pos[1] + child.rect.pos[1],
            },
            .size = child.rect.size,
        });
    }
}

fn onHover(element: *Element, pos: [2]f32) ?*Element {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    for (this.children.items) |child| {
        if (child.rect.contains(pos)) {
            if (child.onHover(.{ pos[0] - child.rect.pos[0], pos[1] - child.rect.pos[1] })) |hovered| {
                return hovered;
            }
        }
    }
    return null;
}

fn onClick(element: *Element, event: ui.event.Click) bool {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);

    for (this.children.items) |child| {
        if (child.rect.contains(event.pos)) {
            if (child.onClick(event.translate(.{ -child.rect.pos[0], -child.rect.pos[1] }))) {
                return true;
            }
        }
    }

    return false;
}

const Rect = ui.Rect;
const Element = ui.Element;
const ui = @import("../ui.zig");
const Canvas = @import("../Canvas.zig");
const utils = @import("utils");
const std = @import("std");
