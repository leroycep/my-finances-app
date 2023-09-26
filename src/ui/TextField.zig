element: Element,
text: std.ArrayListUnmanaged(u8) = .{},
cursor_pos: usize = 0,
selection_start: usize = 0,

userdata: ?*anyopaque = null,
on_enter_fn: ?*const fn (?*anyopaque, *@This()) void = null,

const INTERFACE = Element.Interface{
    .destroy_fn = destroy,
    .layout_fn = layout,
    .render_fn = render,
    .on_hover_fn = onHover,
    .on_click_fn = onClick,
    .on_text_input_fn = onTextInput,
    .on_key_fn = onKey,
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
    this.text.clearAndFree(this.element.manager.gpa);
    this.cursor_pos = 0;
    this.selection_start = 0;
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
    // const text_size = this.element.manager.font.textSize(this.text.items, 1);
    return .{
        max_size[0],
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
            this.element.rect.size[0] - 2 * MARGIN[0],
            canvas.font.lineHeight + 2 * PADDING[1],
        },
        .color = [4]u8{ 0x60, 0x60, 0x60, 0xFF },
    });

    const pre_cursor_size = this.element.manager.font.textSize(this.text.items[0..this.cursor_pos], 1);

    const selection_start = @min(this.cursor_pos, this.selection_start);
    const selection_end = @max(this.cursor_pos, this.selection_start);

    const pre_selection_size = this.element.manager.font.textSize(this.text.items[0..selection_start], 1);
    const selection_size = this.element.manager.font.textSize(this.text.items[selection_start..selection_end], 1);

    canvas.pushScissor(.{
        rect.pos[0] + MARGIN[0],
        rect.pos[1] + MARGIN[1],
    }, .{
        this.element.rect.size[0] - 2 * MARGIN[0],
        canvas.font.lineHeight + 2 * PADDING[1],
    });
    defer canvas.popScissor();

    canvas.writeText(this.text.items, .{
        .pos = .{
            rect.pos[0] + MARGIN[0] + PADDING[0],
            rect.pos[1] + MARGIN[1] + PADDING[1],
        },
        .baseline = .top,
    });
    if (this.element.manager.focused_element == &this.element) {
        canvas.rect(.{
            .pos = .{ rect.pos[0] + MARGIN[0] + PADDING[0] + pre_cursor_size[0], rect.pos[1] + MARGIN[1] + PADDING[1] },
            .size = .{ 1, canvas.font.lineHeight },
        });
        canvas.rect(.{
            .pos = .{ rect.pos[0] + MARGIN[0] + PADDING[0] + pre_selection_size[0], rect.pos[1] + MARGIN[1] + PADDING[1] },
            .size = .{ selection_size[0], selection_size[1] },
            .color = .{ 0xFF, 0xFF, 0xFF, 0xAA },
        });
    }
}

fn onHover(element: *Element, pos: [2]f32) ?*Element {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);

    if (this.element.manager.pointer_capture_element == &this.element) {
        const click_pos = [2]f32{
            pos[0] - MARGIN[0] - PADDING[0],
            pos[1] - MARGIN[1] - PADDING[1],
        };

        // check if the mouse is above or below the text field
        if (pos[1] < 0) {
            this.cursor_pos = 0;
            return &this.element;
        } else if (pos[1] > this.element.rect.size[1]) {
            this.cursor_pos = this.text.items.len;
            return &this.element;
        }

        // check if the mouse is to the left or the right of the text field
        if (pos[0] < 0) {
            this.cursor_pos = 0;
            return &this.element;
        } else if (pos[0] > this.element.rect.size[0]) {
            this.cursor_pos = this.text.items.len;
            return &this.element;
        }

        var layouter = this.element.manager.font.textLayouter(1);
        var prev_x: f32 = 0;
        for (this.text.items, 0..) |character, index| {
            layouter.addCharacter(character);
            if (click_pos[0] >= prev_x and click_pos[0] <= layouter.pos[0]) {
                const dist_prev = click_pos[0] - prev_x;
                const dist_this = layouter.pos[0] - click_pos[0];
                if (dist_prev < dist_this) {
                    this.cursor_pos = index;
                } else {
                    this.cursor_pos = index + 1;
                }
                break;
            }
            prev_x = layouter.pos[0];
        } else {
            this.cursor_pos = this.text.items.len;
        }
    }

    return &this.element;
}

fn onClick(element: *Element, event: ui.event.Click) bool {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    if (!event.pressed and event.button == .left and this.element.manager.pointer_capture_element == &this.element) {
        this.element.manager.pointer_capture_element = null;
    }
    if (!event.pressed or event.button != .left) return false;

    this.element.manager.focused_element = &this.element;
    this.element.manager.pointer_capture_element = &this.element;

    const click_pos = [2]f32{
        event.pos[0] - MARGIN[0] - PADDING[0],
        event.pos[1] - MARGIN[1] - PADDING[1],
    };
    var layouter = this.element.manager.font.textLayouter(1);
    var prev_x: f32 = 0;
    for (this.text.items, 0..) |character, index| {
        layouter.addCharacter(character);
        if (click_pos[0] >= prev_x and click_pos[0] <= layouter.pos[0]) {
            const dist_prev = click_pos[0] - prev_x;
            const dist_this = layouter.pos[0] - click_pos[0];
            if (dist_prev < dist_this) {
                this.selection_start = index;
                this.cursor_pos = index;
            } else {
                this.selection_start = index + 1;
                this.cursor_pos = index + 1;
            }
            break;
        }
        prev_x = layouter.pos[0];
    } else {
        this.selection_start = this.text.items.len;
        this.cursor_pos = this.text.items.len;
    }

    return true;
}

fn onTextInput(element: *Element, event: ui.event.TextInput) bool {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);

    // Delete any text that is currently selected
    const src_pos = @max(this.selection_start, this.cursor_pos);
    const overwrite_pos = @min(this.selection_start, this.cursor_pos);

    const bytes_removed = src_pos - overwrite_pos;
    std.mem.copyForwards(u8, this.text.items[overwrite_pos..], this.text.items[src_pos..]);
    this.text.shrinkRetainingCapacity(this.text.items.len - bytes_removed);

    this.cursor_pos = overwrite_pos;

    // Append new text
    this.text.insertSlice(this.element.manager.gpa, this.cursor_pos, event.text.slice()) catch @panic("OOM");
    this.cursor_pos += event.text.len;
    this.selection_start = this.cursor_pos;

    return true;
}

fn onKey(element: *Element, event: ui.event.Key) bool {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    switch (event.key) {
        .left => if (event.action == .press or event.action == .repeat) {
            this.cursor_pos = if (event.mods.control)
                0
            else
                nextLeft(this.text.items, this.cursor_pos);
            if (!event.mods.shift) {
                this.selection_start = this.cursor_pos;
            }
        },
        .right => if (event.action == .press or event.action == .repeat) {
            this.cursor_pos = if (event.mods.control)
                this.text.items.len
            else
                nextRight(this.text.items, this.cursor_pos);
            if (!event.mods.shift) {
                this.selection_start = this.cursor_pos;
            }
        },
        .backspace => if (event.action == .press or event.action == .repeat) {
            const src_pos = @max(this.selection_start, this.cursor_pos);
            const overwrite_pos = if (this.selection_start == this.cursor_pos)
                nextLeft(this.text.items, this.cursor_pos)
            else
                @min(this.selection_start, this.cursor_pos);

            const bytes_removed = src_pos - overwrite_pos;
            std.mem.copyForwards(u8, this.text.items[overwrite_pos..], this.text.items[src_pos..]);
            this.text.shrinkRetainingCapacity(this.text.items.len - bytes_removed);

            this.cursor_pos = overwrite_pos;
            this.selection_start = overwrite_pos;
        },
        .delete => if (event.action == .press or event.action == .repeat) {
            const src_pos = if (this.selection_start == this.cursor_pos)
                nextRight(this.text.items, this.cursor_pos)
            else
                @max(this.selection_start, this.cursor_pos);
            const overwrite_pos = @min(this.selection_start, this.cursor_pos);

            const bytes_removed = src_pos - overwrite_pos;
            std.mem.copyForwards(u8, this.text.items[overwrite_pos..], this.text.items[src_pos..]);
            this.text.shrinkRetainingCapacity(this.text.items.len - bytes_removed);

            this.cursor_pos = overwrite_pos;
            this.selection_start = overwrite_pos;
        },
        .enter => if (event.action == .press or event.action == .repeat) {
            if (this.on_enter_fn) |on_enter_fn| {
                on_enter_fn(this.userdata, this);
            }
        },
        else => {},
    }
    return true;
}

fn nextLeft(text: []const u8, pos: usize) usize {
    std.debug.assert(pos <= text.len);
    if (pos == 0) return 0;
    var new_pos = pos - 1;
    while (new_pos > 0 and text[new_pos] & 0b1000_0000 != 0b0000_0000) {
        new_pos -= 1;
    }
    return new_pos;
}

fn nextRight(text: []const u8, pos: usize) usize {
    std.debug.assert(pos <= text.len);
    if (pos == text.len) return text.len;
    var new_pos = pos + 1;
    while (new_pos < text.len and text[new_pos] & 0b1000_0000 != 0b0000_0000) {
        new_pos += 1;
    }
    return new_pos;
}

const Rect = ui.Rect;
const Element = ui.Element;
const ui = @import("../ui.zig");
const Canvas = @import("../Canvas.zig");
const utils = @import("utils");
const std = @import("std");
