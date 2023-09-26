element: Element,
/// The size of the ColoredRect before zooming and panning
size: [2]usize = .{ 1, 1 },
/// Value is log-scale, meaning that to get the actual scaling you need to do @exp(zoom)
zoom: f32 = 0,
pan: [2]f32 = .{ 0, 0 },

pan_start: ?[2]f32 = null,
cursor_pos: [2]f32 = .{ 0, 0 },

texture: ?gl.Uint = null,
min_value: f32 = std.math.floatMin(f32),
max_value: f32 = 1,
bg_color: [4]u8 = .{ 0x40, 0x40, 0x40, 0xFF },

children: std.AutoArrayHashMapUnmanaged(*Element, void) = .{},
systems: std.AutoArrayHashMapUnmanaged(?*anyopaque, System) = .{},

const PanZoom = @This();

const System = struct {
    userdata: ?*anyopaque,
    render_fn: RenderFn,

    const RenderFn = *const fn (userdata: ?*anyopaque, pan_zoom: *PanZoom, canvas: *Canvas) void;
};

const INTERFACE = Element.Interface{
    .destroy_fn = destroy,
    .layout_fn = layout,
    .render_fn = render,
    .on_hover_fn = onHover,
    .on_click_fn = onClick,
    .on_scroll_fn = onScroll,
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
    for (this.children.keys()) |child| {
        child.release();
    }
    this.children.deinit(this.element.manager.gpa);
    this.systems.deinit(this.element.manager.gpa);
    this.element.manager.gpa.destroy(this);
}

pub fn appendChild(this: *@This(), child: *Element) !void {
    try this.children.put(this.element.manager.gpa, child, {});
    child.acquire();
    child.parent = &this.element;
}

pub fn layout(element: *Element, min_size: [2]f32, max_size: [2]f32) [2]f32 {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    _ = this;
    _ = min_size;
    return max_size;
}

fn render(element: *Element, canvas: *Canvas, rect: Rect) void {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);

    canvas.rect(.{
        .pos = rect.pos,
        .size = this.element.rect.size,
        .color = this.bg_color,
    });

    const child_size = [2]f32{
        @floatFromInt(this.size[0]),
        @floatFromInt(this.size[1]),
    };

    // Translate to rect position
    canvas.pushTransform(utils.mat4.translate(f32, .{ rect.pos[0], rect.pos[1], 0 }));
    defer canvas.popTransform();

    canvas.pushTransform(panZoomTransform(
        this.element.rect.size,
        child_size,
        this.zoom,
        this.pan,
    ));
    defer canvas.popTransform();

    canvas.rect(.{
        .pos = .{ 0, 0 },
        .size = child_size,
        .color = .{ 0x00, 0x00, 0x00, 0xFF },
    });

    canvas.rect(.{
        .pos = .{ 0, 0 },
        .size = child_size,
        .texture = this.texture,
        .shape = .{ .colormap = .{ .min = this.min_value, .max = this.max_value } },
    });

    for (this.systems.values()) |system| {
        system.render_fn(system.userdata, this, canvas);
    }
    for (this.children.keys()) |child| {
        child.render(canvas, .{ .pos = child.rect.pos, .size = child_size });
    }
}

fn onHover(element: *Element, pos: [2]f32) ?*Element {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);

    this.cursor_pos = pos;
    if (this.pan_start) |pan_start| {
        const inverse = panZoomInverse(
            this.element.rect.size,
            [2]f32{
                @floatFromInt(this.size[0]),
                @floatFromInt(this.size[1]),
            },
            this.zoom,
            pan_start,
        );

        this.pan = utils.mat4.mulVec(f32, inverse, .{
            pos[0],
            pos[1],
            0,
            1,
        })[0..2].*;
    }

    return &this.element;
}

fn onClick(element: *Element, event: ui.event.Click) bool {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    if (event.button != .middle) return false;
    if (!event.pressed) {
        this.element.manager.pointer_capture_element = null;
        this.pan_start = null;
        return true;
    }

    this.element.manager.pointer_capture_element = &this.element;
    const inverse = panZoomInverse(
        this.element.rect.size,
        [2]f32{
            @floatFromInt(this.size[0]),
            @floatFromInt(this.size[1]),
        },
        this.zoom,
        this.pan,
    );

    this.pan_start = utils.mat4.mulVec(f32, inverse, .{
        @as(f32, @floatCast(event.pos[0])),
        @as(f32, @floatCast(event.pos[1])),
        0,
        1,
    })[0..2].*;
    return true;
}

fn onScroll(element: *Element, e: ui.event.Scroll) bool {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);

    const new_zoom = this.zoom + e.offset[1] / 4;
    const child_size = [2]f32{
        @floatFromInt(this.size[0]),
        @floatFromInt(this.size[1]),
    };

    const inverse = panZoomInverse(
        this.element.rect.size,
        child_size,
        this.zoom,
        this.pan,
    );
    const new_inverse = panZoomInverse(
        this.element.rect.size,
        child_size,
        new_zoom,
        this.pan,
    );

    const cursor_before = utils.mat4.mulVec(f32, inverse, this.cursor_pos ++ [2]f32{ 0, 1 });
    const cursor_after = utils.mat4.mulVec(f32, new_inverse, this.cursor_pos ++ [2]f32{ 0, 1 });

    this.zoom = new_zoom;
    this.pan = .{
        this.pan[0] + (cursor_after[0] - cursor_before[0]),
        this.pan[1] + (cursor_after[1] - cursor_before[1]),
    };

    return true;
}

pub fn panZoomTransform(out_size: [2]f32, child_size: [2]f32, zoom_ln: f32, pan: [2]f32) [4][4]f32 {
    const zoom = @exp(zoom_ln);

    const child_aspect = child_size[0] / child_size[1];

    const out_aspect = out_size[0] / out_size[1];

    const aspect = child_aspect / out_aspect;

    const size = if (aspect >= 1)
        [2]f32{
            out_size[0],
            out_size[1] / aspect,
        }
    else
        [2]f32{
            out_size[0] * aspect,
            out_size[1],
        };

    return utils.mat4.mulAll(
        f32,
        &.{
            utils.mat4.translate(f32, .{
                (out_size[0] - size[0]) / 2.0,
                (out_size[1] - size[1]) / 2.0,
                0,
            }),
            utils.mat4.scale(f32, .{
                size[0] / child_size[0],
                size[1] / child_size[1],
                1,
            }),
            utils.mat4.translate(f32, .{
                child_size[0] / 2.0,
                child_size[1] / 2.0,
                0,
            }),
            utils.mat4.scale(f32, .{
                zoom,
                zoom,
                1,
            }),
            utils.mat4.translate(f32, .{
                pan[0],
                pan[1],
                0,
            }),
            utils.mat4.translate(f32, .{
                -child_size[0] / 2.0,
                -child_size[1] / 2.0,
                0,
            }),
        },
    );
}

pub fn panZoomInverse(out_size: [2]f32, child_size: [2]f32, zoom_ln: f32, pan: [2]f32) [4][4]f32 {
    const zoom = @exp(zoom_ln);

    const child_aspect = child_size[0] / child_size[1];

    const out_aspect = out_size[0] / out_size[1];

    const aspect = child_aspect / out_aspect;

    const size = if (aspect >= 1)
        [2]f32{
            out_size[0],
            out_size[1] / aspect,
        }
    else
        [2]f32{
            out_size[0] * aspect,
            out_size[1],
        };

    return utils.mat4.mulAll(f32, &.{
        utils.mat4.translate(f32, .{
            child_size[0] / 2.0,
            child_size[1] / 2.0,
            0,
        }),
        utils.mat4.translate(f32, .{
            -pan[0],
            -pan[1],
            0,
        }),
        utils.mat4.scale(f32, .{
            1.0 / zoom,
            1.0 / zoom,
            1,
        }),
        utils.mat4.translate(f32, .{
            -child_size[0] / 2.0,
            -child_size[1] / 2.0,
            0,
        }),
        utils.mat4.scale(f32, .{
            1.0 / (size[0] / child_size[0]),
            1.0 / (size[1] / child_size[1]),
            1,
        }),
        utils.mat4.translate(f32, .{
            -(out_size[0] - size[0]) / 2.0,
            -(out_size[1] - size[1]) / 2.0,
            0,
        }),
    });
}

const Rect = ui.Rect;
const Element = ui.Element;
const gl = @import("gl");
const ui = @import("../ui.zig");
const Canvas = @import("../Canvas.zig");
const utils = @import("utils");
const std = @import("std");
