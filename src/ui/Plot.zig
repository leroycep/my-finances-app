element: Element,
lines: std.ArrayListUnmanaged(Line) = .{},
x_range: [2]f32 = .{ -1, 1 },
y_range: [2]f32 = .{ -1, 1 },
y_axis_type: AxisType = .linear,

pan_start: ?[2]f32 = null,

hovered_x: f32 = 0,
x_view_range: ?[2]f32 = null,
drag_start_pos: ?[2]f32 = null,

pub const Line = struct {
    x: std.ArrayListUnmanaged(f32) = .{},
    y: std.ArrayListUnmanaged(f32) = .{},
};

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
    for (this.lines.items) |*line| {
        line.x.deinit(this.element.manager.gpa);
        line.y.deinit(this.element.manager.gpa);
    }
    this.lines.deinit(this.element.manager.gpa);
    this.element.manager.gpa.destroy(this);
}

pub fn layout(element: *Element, min_size: [2]f32, max_size: [2]f32) [2]f32 {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    _ = this;
    _ = min_size;
    return max_size;
}

fn render(element: *Element, canvas: *Canvas, rect: Rect) void {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);

    const colormap = Canvas.colormaps.turbo_srgb;
    const step_size = colormap.len / (this.lines.items.len + 1);

    const bg_color = [4]u8{
        @intFromFloat(colormap[0][0] * 0xFF),
        @intFromFloat(colormap[0][1] * 0xFF),
        @intFromFloat(colormap[0][2] * 0xFF),
        0xFF,
    };

    canvas.rect(.{
        .pos = rect.pos,
        .size = rect.size,
        .color = bg_color,
    });

    canvas.pushScissor(rect.pos, rect.size);
    defer canvas.popScissor();

    const transform = rangeTransform(
        rect.size,
        .{ .linear, this.y_axis_type },
        .{
            if (this.x_view_range) |vr| vr[0] else this.x_range[0],
            this.y_range[0],
        },
        .{
            if (this.x_view_range) |vr| vr[1] else this.x_range[1],
            this.y_range[1],
        },
    );

    for (this.lines.items, 0..) |line, line_index| {
        for (line.x.items[0 .. line.x.items.len - 1], line.x.items[1..], line.y.items[0 .. line.y.items.len - 1], line.y.items[1..]) |x0, x1, y0_raw, y1_raw| {
            const y0 = switch (this.y_axis_type) {
                .linear => y0_raw,
                .log => @log(y0_raw),
            };
            const y1 = switch (this.y_axis_type) {
                .linear => y1_raw,
                .log => @log(y1_raw),
            };

            const colormap_index = (line_index + 1) * step_size;
            const line_color = [4]u8{
                @intFromFloat(colormap[colormap_index][0] * 0xFF),
                @intFromFloat(colormap[colormap_index][1] * 0xFF),
                @intFromFloat(colormap[colormap_index][2] * 0xFF),
                0xFF,
            };

            const line_pos0 = utils.mat4.mulVec(f32, transform, .{ x0, y0, 0, 1 })[0..2].*;
            const line_pos1 = utils.mat4.mulVec(f32, transform, .{ x1, y1, 0, 1 })[0..2].*;

            canvas.line(
                .{ rect.pos[0] + line_pos0[0], rect.pos[1] + line_pos0[1] },
                .{ rect.pos[0] + line_pos1[0], rect.pos[1] + line_pos1[1] },
                .{ .width = 1.5, .color = line_color },
            );
        }
    }

    const hover_hline_pos = utils.mat4.mulVec(f32, transform, .{ this.hovered_x, 0, 0, 1 })[0..2].*;
    if (this.drag_start_pos) |start_pos| {
        const drag_pos = utils.mat4.mulVec(f32, transform, .{ start_pos[0], 0, 0, 1 })[0..2].*;
        canvas.rect(.{
            .pos = .{ rect.pos[0] + drag_pos[0], rect.pos[1] },
            .size = .{ hover_hline_pos[0] - drag_pos[0], rect.size[1] },
            .color = .{ 0xFF, 0xFF, 0x00, 0x80 },
        });
    }
    if (this.element.manager.hovered_element == &this.element) {
        canvas.line(
            .{ rect.pos[0] + hover_hline_pos[0], rect.pos[1] },
            .{ rect.pos[0] + hover_hline_pos[0], rect.pos[1] + rect.size[1] },
            .{ .color = .{ 0xFF, 0xFF, 0x00, 0xFF } },
        );
    }
}

fn onHover(element: *Element, pos: [2]f32) ?*Element {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);

    if (this.pan_start) |start| {
        const size = if (this.x_view_range) |vr| vr[1] - vr[0] else this.x_range[1] - this.x_range[0];

        const inverse = rangeTransformInverse(
            this.element.rect.size,
            .{ .linear, this.y_axis_type },
            .{
                start[0],
                this.y_range[0],
            },
            .{
                start[0] + size,
                this.y_range[1],
            },
        );

        const new_min = utils.mat4.mulVec(f32, inverse, .{
            -pos[0],
            -pos[1],
            0,
            1,
        })[0..2].*;

        this.x_view_range = [2]f32{
            new_min[0],
            new_min[0] + size,
        };
    }

    const inverse = rangeTransformInverse(
        this.element.rect.size,
        .{ .linear, this.y_axis_type },
        .{
            if (this.x_view_range) |vr| vr[0] else this.x_range[0],
            this.y_range[0],
        },
        .{
            if (this.x_view_range) |vr| vr[1] else this.x_range[1],
            this.y_range[1],
        },
    );

    this.hovered_x = utils.mat4.mulVec(f32, inverse, .{ pos[0], 0, 0, 1 })[0];

    return element;
}

fn onClick(element: *Element, event: ui.event.Click) bool {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    switch (event.button) {
        .left => {
            if (this.x_view_range) |_| {
                this.x_view_range = null;

                const inverse = rangeTransformInverse(
                    this.element.rect.size,
                    .{ .linear, this.y_axis_type },
                    .{ this.x_range[0], this.y_range[0] },
                    .{ this.x_range[1], this.y_range[1] },
                );

                this.hovered_x = utils.mat4.mulVec(f32, inverse, .{ event.pos[0], 0, 0, 1 })[0];

                return true;
            }

            const inverse = rangeTransformInverse(
                this.element.rect.size,
                .{ .linear, this.y_axis_type },
                .{
                    if (this.x_view_range) |vr| vr[0] else this.x_range[0],
                    this.y_range[0],
                },
                .{
                    if (this.x_view_range) |vr| vr[1] else this.x_range[1],
                    this.y_range[1],
                },
            );
            const pos = utils.mat4.mulVec(f32, inverse, .{
                event.pos[0],
                event.pos[1],
                0,
                1,
            })[0..2].*;

            if (event.pressed) {
                this.drag_start_pos = pos;

                this.element.manager.pointer_capture_element = &this.element;
            } else if (this.drag_start_pos) |start_pos| {
                this.element.manager.pointer_capture_element = null;

                this.x_view_range = .{ @min(start_pos[0], pos[0]), @max(start_pos[0], pos[0]) };

                // update hovered position
                const new_transform = rangeTransform(
                    this.element.rect.size,
                    .{ .linear, this.y_axis_type },
                    .{
                        if (this.x_view_range) |vr| vr[0] else this.x_range[0],
                        this.y_range[0],
                    },
                    .{
                        if (this.x_view_range) |vr| vr[1] else this.x_range[1],
                        this.y_range[1],
                    },
                );
                this.hovered_x = utils.mat4.mulVec(f32, new_transform, .{
                    event.pos[0],
                    event.pos[1],
                    0,
                    1,
                })[0];

                this.drag_start_pos = null;
            }
        },

        .middle => {
            if (event.pressed) {
                const inverse = rangeTransformInverse(
                    this.element.rect.size,
                    .{ .linear, this.y_axis_type },
                    .{
                        if (this.x_view_range) |vr| vr[0] else this.x_range[0],
                        this.y_range[0],
                    },
                    .{
                        if (this.x_view_range) |vr| vr[1] else this.x_range[1],
                        this.y_range[1],
                    },
                );

                this.pan_start = utils.mat4.mulVec(f32, inverse, .{
                    event.pos[0],
                    event.pos[1],
                    0,
                    1,
                })[0..2].*;

                this.element.manager.pointer_capture_element = &this.element;
            } else {
                this.pan_start = null;

                if (this.element.manager.pointer_capture_element == &this.element) {
                    this.element.manager.pointer_capture_element = null;
                }
            }
        },

        else => {},
    }

    return true;
}

pub fn rangeTransform(out_size: [2]f32, axis_types: [2]AxisType, min_coord_raw: [2]f32, max_coord_raw: [2]f32) [4][4]f32 {
    const min_coord = [2]f32{
        switch (axis_types[0]) {
            .linear => min_coord_raw[0],
            .log => @log(min_coord_raw[0]),
        },
        switch (axis_types[1]) {
            .linear => min_coord_raw[1],
            .log => @log(min_coord_raw[1]),
        },
    };

    const size = [2]f32{
        switch (axis_types[0]) {
            .linear => max_coord_raw[0] - min_coord_raw[0],
            .log => @log(max_coord_raw[0]) - @log(min_coord_raw[1]),
        },
        switch (axis_types[1]) {
            .linear => max_coord_raw[1] - min_coord_raw[1],
            .log => @log(max_coord_raw[1]) - @log(min_coord_raw[1]),
        },
    };

    return utils.mat4.mulAll(
        f32,
        &.{
            utils.mat4.scale(f32, .{
                1,
                -1,
                1,
            }),
            utils.mat4.translate(f32, .{
                0,
                -out_size[1],
                0,
            }),
            utils.mat4.scale(f32, .{
                out_size[0] / size[0],
                out_size[1] / size[1],
                1,
            }),
            utils.mat4.translate(f32, .{
                -min_coord[0],
                -min_coord[1],
                0,
            }),
        },
    );
}

pub fn rangeTransformInverse(out_size: [2]f32, axis_types: [2]AxisType, min_coord_raw: [2]f32, max_coord_raw: [2]f32) [4][4]f32 {
    const min_coord = [2]f32{
        switch (axis_types[0]) {
            .linear => min_coord_raw[0],
            .log => @log(min_coord_raw[0]),
        },
        switch (axis_types[1]) {
            .linear => min_coord_raw[1],
            .log => @log(min_coord_raw[1]),
        },
    };

    const size = [2]f32{
        switch (axis_types[0]) {
            .linear => max_coord_raw[0] - min_coord_raw[0],
            .log => @log(max_coord_raw[0]) - @log(min_coord_raw[1]),
        },
        switch (axis_types[1]) {
            .linear => max_coord_raw[1] - min_coord_raw[1],
            .log => @log(max_coord_raw[1]) - @log(min_coord_raw[1]),
        },
    };

    return utils.mat4.mulAll(
        f32,
        &.{
            utils.mat4.translate(f32, .{
                min_coord[0],
                min_coord[1],
                0,
            }),
            utils.mat4.scale(f32, .{
                size[0] / out_size[0],
                size[1] / out_size[1],
                1,
            }),
            utils.mat4.translate(f32, .{
                0,
                out_size[1],
                0,
            }),
            utils.mat4.scale(f32, .{
                1,
                -1,
                1,
            }),
        },
    );
}

const Rect = ui.Rect;
const Element = ui.Element;
const gl = @import("gl");
const ui = @import("../ui.zig");
const Canvas = @import("../Canvas.zig");
const utils = @import("utils");
const std = @import("std");
