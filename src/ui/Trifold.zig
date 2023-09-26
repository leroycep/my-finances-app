element: Element,
top_bar: ?*Element = null,
bottom_bar: ?*Element = null,
left_window: ?*Element = null,
right_window: ?*Element = null,
main_content: ?*Element = null,

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
    if (this.top_bar) |top_bar| {
        top_bar.release();
    }

    if (this.bottom_bar) |bottom_bar| {
        bottom_bar.release();
    }

    if (this.left_window) |left_window| {
        left_window.release();
    }

    if (this.right_window) |right_window| {
        right_window.release();
    }

    if (this.main_content) |main_content| {
        main_content.release();
    }
    this.element.manager.gpa.destroy(this);
}

const Pane = enum {
    main,
    left,
    right,
    top,
    bottom,
};

pub fn setPane(this: *@This(), pane: Pane, new_child_opt: ?*Element) void {
    if (new_child_opt) |new_child| {
        new_child.acquire();
    }
    switch (pane) {
        .main => {
            if (this.main_content) |old| {
                old.parent = null;
                old.release();
            }
            this.main_content = new_child_opt;
        },
        .left => {
            if (this.left_window) |old| {
                old.parent = null;
                old.release();
            }
            this.left_window = new_child_opt;
        },
        .right => {
            if (this.right_window) |old| {
                old.parent = null;
                old.release();
            }
            this.right_window = new_child_opt;
        },
        .top => {
            if (this.top_bar) |old| {
                old.parent = null;
                old.release();
            }
            this.top_bar = new_child_opt;
        },
        .bottom => {
            if (this.bottom_bar) |old| {
                old.parent = null;
                old.release();
            }
            this.bottom_bar = new_child_opt;
        },
    }
    if (new_child_opt) |new_child| {
        new_child.parent = &this.element;
    }
    this.element.manager.needs_layout = true;
}

pub fn layout(element: *Element, min_size: [2]f32, max_size: [2]f32) [2]f32 {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);

    var main_top: f32 = 0;
    var main_left: f32 = 0;
    var remaining_space = max_size;

    if (this.top_bar) |top_bar| {
        top_bar.rect.size = top_bar.layout(.{ max_size[0], min_size[1] }, remaining_space);
        top_bar.rect.pos = .{ 0, 0 };
        main_top = top_bar.rect.size[1];
        remaining_space[1] -= top_bar.rect.size[1];
    }

    if (this.bottom_bar) |bottom_bar| {
        bottom_bar.rect.size = bottom_bar.layout(.{ max_size[0], min_size[1] }, remaining_space);
        bottom_bar.rect.pos = .{ 0, max_size[1] - bottom_bar.rect.size[1] };
        remaining_space[1] -= bottom_bar.rect.size[1];
    }

    if (this.left_window) |left_window| {
        left_window.rect.size = left_window.layout(
            .{ min_size[0], remaining_space[1] },
            .{ @min(remaining_space[0], max_size[0] / 4), remaining_space[1] },
        );
        left_window.rect.pos = .{ 0, main_top };
        main_left = left_window.rect.size[0];
        remaining_space[0] -= left_window.rect.size[0];
    }

    if (this.right_window) |right_window| {
        right_window.rect.size = right_window.layout(
            .{ min_size[0], remaining_space[1] },
            .{ @min(remaining_space[0], max_size[0] / 4), remaining_space[1] },
        );
        right_window.rect.pos = .{ max_size[0] - right_window.rect.size[0], main_top };
        remaining_space[0] -= right_window.rect.size[0];
    }

    if (this.main_content) |main_content| {
        main_content.rect.size = main_content.layout(.{ min_size[0], remaining_space[1] }, remaining_space);
        main_content.rect.pos = .{ main_left, main_top };
    }

    return max_size;
}

fn render(element: *Element, canvas: *Canvas, rect: Rect) void {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);

    if (this.main_content) |main_content| {
        main_content.render(canvas, .{
            .pos = .{
                rect.pos[0] + main_content.rect.pos[0],
                rect.pos[1] + main_content.rect.pos[1],
            },
            .size = main_content.rect.size,
        });
    }

    if (this.right_window) |right_window| {
        canvas.rect(.{
            .pos = .{
                rect.pos[0] + right_window.rect.pos[0],
                rect.pos[1] + right_window.rect.pos[1],
            },
            .size = right_window.rect.size,
            .color = [4]u8{ 0x30, 0x30, 0x30, 0xFF },
        });
        right_window.render(canvas, .{
            .pos = .{
                rect.pos[0] + right_window.rect.pos[0],
                rect.pos[1] + right_window.rect.pos[1],
            },
            .size = right_window.rect.size,
        });
    }

    if (this.left_window) |left_window| {
        canvas.rect(.{
            .pos = .{
                rect.pos[0] + left_window.rect.pos[0],
                rect.pos[1] + left_window.rect.pos[1],
            },
            .size = left_window.rect.size,
            .color = [4]u8{ 0x30, 0x30, 0x30, 0xFF },
        });
        left_window.render(canvas, .{
            .pos = .{
                rect.pos[0] + left_window.rect.pos[0],
                rect.pos[1] + left_window.rect.pos[1],
            },
            .size = left_window.rect.size,
        });
    }

    if (this.top_bar) |top_bar| {
        canvas.rect(.{
            .pos = .{
                rect.pos[0] + top_bar.rect.pos[0],
                rect.pos[1] + top_bar.rect.pos[1],
            },
            .size = top_bar.rect.size,
            .color = [4]u8{ 0x30, 0x30, 0x30, 0xFF },
        });
        top_bar.render(canvas, .{
            .pos = .{
                rect.pos[0] + top_bar.rect.pos[0],
                rect.pos[1] + top_bar.rect.pos[1],
            },
            .size = top_bar.rect.size,
        });
    }

    if (this.bottom_bar) |bottom_bar| {
        canvas.rect(.{
            .pos = .{
                rect.pos[0] + bottom_bar.rect.pos[0],
                rect.pos[1] + bottom_bar.rect.pos[1],
            },
            .size = bottom_bar.rect.size,
            .color = [4]u8{ 0x30, 0x30, 0x30, 0xFF },
        });
        bottom_bar.render(canvas, .{
            .pos = .{
                rect.pos[0] + bottom_bar.rect.pos[0],
                rect.pos[1] + bottom_bar.rect.pos[1],
            },
            .size = bottom_bar.rect.size,
        });
    }
}

fn onHover(element: *Element, pos: [2]f32) ?*Element {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);

    if (this.top_bar) |top_bar| {
        if (top_bar.rect.contains(pos)) {
            if (top_bar.onHover(.{ pos[0] - top_bar.rect.pos[0], pos[1] - top_bar.rect.pos[1] })) |hovered| {
                return hovered;
            }
        }
    }

    if (this.bottom_bar) |bottom_bar| {
        if (bottom_bar.rect.contains(pos)) {
            if (bottom_bar.onHover(.{ pos[0] - bottom_bar.rect.pos[0], pos[1] - bottom_bar.rect.pos[1] })) |hovered| {
                return hovered;
            }
        }
    }

    if (this.left_window) |left_window| {
        if (left_window.rect.contains(pos)) {
            if (left_window.onHover(.{ pos[0] - left_window.rect.pos[0], pos[1] - left_window.rect.pos[1] })) |hovered| {
                return hovered;
            }
        }
    }

    if (this.right_window) |right_window| {
        if (right_window.rect.contains(pos)) {
            if (right_window.onHover(.{ pos[0] - right_window.rect.pos[0], pos[1] - right_window.rect.pos[1] })) |hovered| {
                return hovered;
            }
        }
    }

    if (this.main_content) |main_content| {
        if (main_content.rect.contains(pos)) {
            if (main_content.onHover(.{ pos[0] - main_content.rect.pos[0], pos[1] - main_content.rect.pos[1] })) |hovered| {
                return hovered;
            }
        }
    }

    return null;
}

fn onClick(element: *Element, e: ui.event.Click) bool {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);

    if (this.top_bar) |top_bar| {
        if (top_bar.rect.contains(e.pos)) {
            if (top_bar.onClick(e.translate(.{ -top_bar.rect.pos[0], -top_bar.rect.pos[1] }))) {
                return true;
            }
        }
    }

    if (this.bottom_bar) |bottom_bar| {
        if (bottom_bar.rect.contains(e.pos)) {
            if (bottom_bar.onClick(e.translate(.{ -bottom_bar.rect.pos[0], -bottom_bar.rect.pos[1] }))) {
                return true;
            }
        }
    }

    if (this.left_window) |left_window| {
        if (left_window.rect.contains(e.pos)) {
            if (left_window.onClick(e.translate(.{ -left_window.rect.pos[0], -left_window.rect.pos[1] }))) {
                return true;
            }
        }
    }

    if (this.right_window) |right_window| {
        if (right_window.rect.contains(e.pos)) {
            if (right_window.onClick(e.translate(.{ -right_window.rect.pos[0], -right_window.rect.pos[1] }))) {
                return true;
            }
        }
    }

    if (this.main_content) |main_content| {
        if (main_content.rect.contains(e.pos)) {
            if (main_content.onClick(e.translate(.{ -main_content.rect.pos[0], -main_content.rect.pos[1] }))) {
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
