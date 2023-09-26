element: Element,
title: []const u8 = "Popup",
child: ?*Element = null,

title_rect: ui.Rect = .{ .pos = .{ 0, 0 }, .size = .{ 0, 0 } },
close_button_rect: ui.Rect = .{ .pos = .{ 0, 0 }, .size = .{ 0, 0 } },
close_button_hovered: bool = false,
grab_pos: [2]f32 = .{ 0, 0 },
resize_edge: ?ResizeEdge = null,

const ResizeEdge = enum {
    left,
    right,
    top,
    bottom,
    top_left,
    top_right,
    bottom_left,
    bottom_right,
};

const INTERFACE = Element.Interface{
    .destroy_fn = destroy,
    .layout_fn = layout,
    .render_fn = render,
    .on_hover_fn = onHover,
    .on_click_fn = onClick,
};

const RESIZE_MARGIN = 5;
const CLOSE_BUTTON_TEXT = "[X]";

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
    if (this.child) |child| {
        child.release();
    }
    this.element.manager.gpa.destroy(this);
}

pub fn setChild(this: *@This(), new_child_opt: ?*Element) void {
    // Acquire the new child before releasing the previous one, in case the elements are the same
    if (new_child_opt) |new_child| {
        new_child.acquire();
    }

    if (this.child) |child| {
        child.parent = null;
        child.release();
    }

    this.child = new_child_opt;
    if (new_child_opt) |new_child| {
        new_child.parent = &this.element;
    }
}

pub fn layout(element: *Element, min_size: [2]f32, max_size: [2]f32) [2]f32 {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    _ = min_size;

    this.title_rect.size = this.element.manager.font.textSize(this.title, 1);
    this.close_button_rect.size = this.element.manager.font.textSize(CLOSE_BUTTON_TEXT, 1);

    this.element.rect.size = .{
        std.math.clamp(this.element.rect.size[0], this.title_rect.size[0] + this.close_button_rect.size[0] + 2 * RESIZE_MARGIN, max_size[0]),
        std.math.clamp(this.element.rect.size[1], this.title_rect.size[1] + this.close_button_rect.size[1] + 2 * RESIZE_MARGIN, max_size[1]),
    };

    this.title_rect.pos = .{
        RESIZE_MARGIN + (this.element.rect.size[0] - this.title_rect.size[0] - this.close_button_rect.size[0] - 2 * RESIZE_MARGIN) / 2,
        RESIZE_MARGIN,
    };

    this.close_button_rect.pos = .{
        this.element.rect.size[0] - RESIZE_MARGIN - this.close_button_rect.size[0],
        RESIZE_MARGIN,
    };

    if (this.child) |child| {
        child.rect.pos[0] = RESIZE_MARGIN;
        child.rect.pos[1] = this.title_rect.pos[1] + @max(this.title_rect.size[1], this.close_button_rect.size[1]);
        const frame_size = [2]f32{
            this.element.rect.size[0] - 2 * RESIZE_MARGIN,
            this.element.rect.size[1] - child.rect.pos[1] - 2 * RESIZE_MARGIN,
        };
        child.rect.size = child.layout(frame_size, frame_size);
    }

    return this.element.rect.size;
}

fn render(element: *Element, canvas: *Canvas, rect: Rect) void {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    canvas.rect(.{
        .pos = rect.pos,
        .size = rect.size,
        .color = [4]u8{ 0x11, 0x11, 0x11, 0xFF },
    });
    if (this.child) |child| {
        canvas.pushScissor(.{
            rect.pos[0] + child.rect.pos[0],
            rect.pos[1] + child.rect.pos[1],
        }, child.rect.size);
        defer canvas.popScissor();

        child.render(canvas, .{
            .pos = .{
                rect.pos[0] + child.rect.pos[0],
                rect.pos[1] + child.rect.pos[1],
            },
            .size = child.rect.size,
        });
    }
    canvas.rect(.{
        .pos = rect.pos,
        .size = .{
            rect.size[0],
            this.title_rect.pos[1] + this.title_rect.size[1],
        },
        .color = [4]u8{ 0x44, 0x11, 0x11, 0xFF },
    });
    _ = canvas.writeText(this.title, .{
        .pos = .{
            rect.pos[0] + this.title_rect.pos[0],
            rect.pos[1] + this.title_rect.pos[1],
        },
        .baseline = .top,
    });
    _ = canvas.writeText(CLOSE_BUTTON_TEXT, .{
        .pos = .{
            rect.pos[0] + this.close_button_rect.pos[0],
            rect.pos[1] + this.close_button_rect.pos[1],
        },
        .baseline = .top,
        .color = if (this.element.manager.hovered_element == &this.element and this.close_button_hovered) [4]u8{ 0xFF, 0xFF, 0x00, 0xFF } else [4]u8{ 0xFF, 0xFF, 0xFF, 0xFF },
    });
}

fn onHover(element: *Element, pos: [2]f32) ?*Element {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    this.close_button_hovered = this.close_button_rect.contains(pos);

    // Update size and position if the element is being resized
    if (this.element.manager.pointer_capture_element == &this.element) {
        if (this.resize_edge) |edge| {
            switch (edge) {
                .right => {
                    this.element.manager.cursor_shape = .horizontal_resize;
                    this.element.rect.size[0] = pos[0];
                },
                .bottom => {
                    this.element.manager.cursor_shape = .vertical_resize;
                    this.element.rect.size[1] = pos[1];
                },
                .left => {
                    this.element.manager.cursor_shape = .horizontal_resize;
                    this.element.rect.pos[0] += pos[0];
                    this.element.rect.size[0] -= pos[0];
                },
                .top => {
                    this.element.manager.cursor_shape = .vertical_resize;
                    this.element.rect.pos[1] += pos[1];
                    this.element.rect.size[1] -= pos[1];
                },
                .top_left => {
                    this.element.manager.cursor_shape = .nw_to_se_resize;
                    this.element.rect.pos[0] += pos[0];
                    this.element.rect.size[0] -= pos[0];
                    this.element.rect.pos[1] += pos[1];
                    this.element.rect.size[1] -= pos[1];
                },
                .top_right => {
                    this.element.manager.cursor_shape = .sw_to_ne_resize;
                    this.element.rect.size[0] = pos[0];
                    this.element.rect.pos[1] += pos[1];
                    this.element.rect.size[1] -= pos[1];
                },
                .bottom_left => {
                    this.element.manager.cursor_shape = .sw_to_ne_resize;
                    this.element.rect.pos[0] += pos[0];
                    this.element.rect.size[0] -= pos[0];
                    this.element.rect.size[1] = pos[1];
                },
                .bottom_right => {
                    this.element.manager.cursor_shape = .nw_to_se_resize;
                    this.element.rect.size[0] = pos[0];
                    this.element.rect.size[1] = pos[1];
                },
            }
            this.element.manager.needs_layout = true;
        } else {
            this.element.rect.pos = .{
                this.element.rect.pos[0] + pos[0] - this.grab_pos[0],
                this.element.rect.pos[1] + pos[1] - this.grab_pos[1],
            };
        }
        return &this.element;
    }

    // Set cursor graphic
    if (getEdgeAtPos(pos, this.element.rect.size)) |edge| {
        switch (edge) {
            .left,
            .right,
            => this.element.manager.cursor_shape = .horizontal_resize,

            .top_right,
            .bottom_left,
            => this.element.manager.cursor_shape = .sw_to_ne_resize,

            .top_left,
            .bottom_right,
            => this.element.manager.cursor_shape = .nw_to_se_resize,

            .top,
            .bottom,
            => this.element.manager.cursor_shape = .vertical_resize,
        }
    }

    if (this.child) |child| {
        if (child.rect.contains(pos)) {
            if (child.onHover(.{
                pos[0] - child.rect.pos[0],
                pos[1] - child.rect.pos[1],
            })) |hovered| {
                return hovered;
            }
        }
    }
    return &this.element;
}

fn onClick(element: *Element, event: ui.event.Click) bool {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    if (!event.pressed and event.button == .left and this.element.manager.pointer_capture_element == &this.element) {
        this.element.manager.pointer_capture_element = null;
        this.resize_edge = null;
    }

    if (event.pressed and event.button == .left) {
        // Check if close button was clicked
        if (this.close_button_rect.contains(event.pos)) {
            _ = this.element.manager.removePopup(&this.element);
            return true;
        }

        // Check if resizing areas were clicked
        if (getEdgeAtPos(event.pos, this.element.rect.size)) |edge| {
            this.element.manager.pointer_capture_element = &this.element;
            this.resize_edge = edge;
            return true;
        }

        // Check if window move area was clicked
        if (this.title_rect.pos[1] <= event.pos[1] and event.pos[1] <= this.title_rect.pos[1] + this.title_rect.size[1]) {
            this.element.manager.pointer_capture_element = &this.element;
            this.grab_pos = event.pos;
            return true;
        }
    }

    if (this.child) |child| {
        if (child.rect.contains(event.pos)) {
            if (child.onClick(event.translate(.{ -child.rect.pos[0], -child.rect.pos[1] }))) {
                return true;
            }
        }
    }
    return true;
}

fn getEdgeAtPos(cursor_pos: [2]f32, rect_size: [2]f32) ?ResizeEdge {
    // Diagonal edges
    if (cursor_pos[0] >= rect_size[0] - RESIZE_MARGIN and cursor_pos[1] >= rect_size[1] - RESIZE_MARGIN) {
        return .bottom_right;
    }
    if (cursor_pos[1] >= rect_size[1] - RESIZE_MARGIN and cursor_pos[0] <= RESIZE_MARGIN) {
        return .bottom_left;
    }
    if (cursor_pos[1] <= RESIZE_MARGIN and cursor_pos[0] >= rect_size[0] - RESIZE_MARGIN) {
        return .top_right;
    }
    if (cursor_pos[1] <= RESIZE_MARGIN and cursor_pos[0] <= RESIZE_MARGIN) {
        return .top_left;
    }

    // Cardinal edges
    if (cursor_pos[0] >= rect_size[0] - RESIZE_MARGIN) {
        return .right;
    }
    if (cursor_pos[1] >= rect_size[1] - RESIZE_MARGIN) {
        return .bottom;
    }
    if (cursor_pos[0] <= RESIZE_MARGIN) {
        return .left;
    }
    if (cursor_pos[1] <= RESIZE_MARGIN) {
        return .top;
    }

    return null;
}

const Rect = ui.Rect;
const Element = ui.Element;
const ui = @import("../ui.zig");
const Canvas = @import("../Canvas.zig");
const utils = @import("utils");
const std = @import("std");
