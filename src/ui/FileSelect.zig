element: Element,
arena: std.heap.ArenaAllocator,
file_names: std.ArrayListUnmanaged([]const u8) = .{},
file_kinds: std.ArrayListUnmanaged(std.fs.IterableDir.Entry.Kind) = .{},
rects: std.ArrayListUnmanaged(Rect) = .{},
selected: usize = 0,
hovered: ?usize = null,

directory: std.fs.IterableDir,

userdata: ?*anyopaque = null,
on_file_open_fn: ?FileOpenCallback = null,

const INTERFACE = Element.Interface{
    .destroy_fn = destroy,
    .layout_fn = layout,
    .render_fn = render,
    .on_hover_fn = onHover,
    .on_click_fn = onClick,
};

const FileSelect = @This();

const FileOpenCallback = *const fn (?*anyopaque, *FileSelect) void;

pub fn init(element: *Element, manager: *ui.Manager) !void {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    this.* = .{
        .element = .{
            .manager = manager,
            .interface = &INTERFACE,
        },
        .arena = std.heap.ArenaAllocator.init(manager.gpa),
        .directory = try std.fs.cwd().openIterableDir(".", .{}),
    };
    try this.refreshFiles();
}

pub fn destroy(element: *Element) void {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    this.file_names.deinit(this.element.manager.gpa);
    this.file_kinds.deinit(this.element.manager.gpa);
    this.rects.deinit(this.element.manager.gpa);
    this.arena.deinit();
    this.element.manager.gpa.destroy(this);
}

pub fn refreshFiles(this: *@This()) !void {
    _ = this.arena.reset(.retain_capacity);
    this.file_names.clearRetainingCapacity();
    this.file_kinds.clearRetainingCapacity();

    try this.file_names.append(this.element.manager.gpa, "..");
    try this.file_kinds.append(this.element.manager.gpa, .directory);

    var iter = this.directory.iterate();
    while (try iter.next()) |entry| {
        try this.file_kinds.append(this.element.manager.gpa, entry.kind);
        switch (entry.kind) {
            .directory => {
                const name = try std.fmt.allocPrint(this.arena.allocator(), "{s}/", .{entry.name});
                try this.file_names.append(this.element.manager.gpa, name);
            },
            else => {
                const name = try this.arena.allocator().dupe(u8, entry.name);
                try this.file_names.append(this.element.manager.gpa, name);
            },
        }
    }
    this.element.manager.needs_layout = true;
}

pub fn layout(element: *Element, min_size: [2]f32, max_size: [2]f32) [2]f32 {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    this.rects.resize(this.element.manager.gpa, this.file_names.items.len) catch @panic("OOM");

    _ = min_size;

    var max_width: f32 = 0;
    var pos = [2]f32{
        4,
        4,
    };
    for (this.file_names.items, this.rects.items) |name, *rect| {
        rect.pos = pos;
        rect.size = this.element.manager.font.textSize(name, 1);
        max_width = @max(max_width, rect.size[0]);
        pos[1] += this.element.manager.font.lineHeight * 2;
    }

    return .{ max_width + 8, max_size[1] };
}

fn render(element: *Element, canvas: *Canvas, rect: Rect) void {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);

    const is_hovered = this.element.manager.hovered_element == &this.element;
    // set hovered_index to rects.len if nothing is hovered, so that i in the loop below is never equal to hovered_index
    const hovered_index = if (this.hovered) |h| h else this.rects.items.len;

    for (this.file_names.items, this.rects.items, 0..) |name, name_rect, i| {
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
            if (this.selected == i) {
                const kind = this.file_kinds.items[i];
                if (kind == .directory) {
                    const new_dir = this.directory.dir.openIterableDir(this.file_names.items[i], .{}) catch |err| {
                        std.log.warn("Could not open directory: {}", .{err});
                        return true;
                    };
                    this.directory = new_dir;
                    this.selected = 0;
                    this.refreshFiles() catch |err| {
                        std.log.warn("Could not open directory: {}", .{err});
                        return true;
                    };
                } else {
                    if (this.on_file_open_fn) |on_file_open_fn| {
                        on_file_open_fn(this.userdata, this);
                    }
                }
            } else {
                this.setSelected(i);
            }
            return true;
        }
    }
    return false;
}

pub fn setSelected(this: *@This(), selection: usize) void {
    std.debug.assert(selection < this.file_names.items.len);

    this.selected = selection;
}

const Rect = ui.Rect;
const Element = ui.Element;
const ui = @import("../ui.zig");
const Canvas = @import("../Canvas.zig");
const std = @import("std");
