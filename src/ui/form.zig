pub fn InputFields(comptime Data: type) type {
    const data_fields = std.meta.fields(Data);
    var input_fields: [data_fields.len]std.builtin.Type.StructField = undefined;
    for (data_fields, &input_fields) |data, *input| {
        const input_type = switch (data.type) {
            []const u8 => *ui.TextField,
            f32 => *ui.NumberField,
            else => @compileError("Unsupported type " ++ @typeName(data.type) ++ " in InputFields."),
        };
        input.* = .{
            .name = data.name,
            .type = input_type,
            .default_value = null,
            .is_comptime = false,
            .alignment = @alignOf(input_type),
        };
    }
    return @Type(std.builtin.Type{ .Struct = .{
        .layout = .Auto,
        .fields = &input_fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

const DEFAULT_SUBMIT_TEXT = "[submit]";

pub fn Form(comptime Data: type) type {
    return struct {
        element: Element,
        inputs: InputFields(Data) = undefined,
        max_name_width: f32 = 0,
        submit_button: ui.Button = undefined,

        userdata: ?*anyopaque = null,
        on_change_fn: ?*const fn (?*anyopaque, *@This()) void = null,
        on_submit_fn: ?*const fn (?*anyopaque, Data) void = null,

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

            const data_fields = std.meta.fields(Data);
            const input_fields = std.meta.fields(InputFields(Data));
            inline for (input_fields, data_fields) |input_field, data_field| {
                const input = try manager.create(@typeInfo(input_field.type).Pointer.child);
                @field(this.inputs, input_field.name) = input;
                if (data_field.default_value) |default| {
                    switch (data_field.type) {
                        []const u8 => try input.text.appendSlice(manager.gpa, @as(*const []const u8, @ptrCast(@alignCast(default))).*),
                        f32 => input.number = @as(*const f32, @ptrCast(@alignCast(default))).*,
                        else => @compileError("Unsupported type " ++ @typeName(data_field.type) ++ " in InputFields."),
                    }
                }

                // Set callbacks
                switch (data_field.type) {
                    []const u8 => {
                        // TODO: Implement text change handler
                        input.userdata = this;
                        input.on_enter_fn = onTextFieldEnter;
                    },
                    f32 => {
                        input.userdata = this;
                        input.on_change_fn = onNumberFieldChanged;
                    },
                    else => @compileError("Unsupported type " ++ @typeName(data_field.type) ++ " in InputFields."),
                }

                input.element.parent = &this.element;
            }

            try ui.Button.init(&this.submit_button.element, manager);
            this.submit_button.text = DEFAULT_SUBMIT_TEXT;
            this.submit_button.userdata = this;
            this.submit_button.on_click_fn = onSubmitButtonClicked;
        }

        pub fn destroy(element: *Element) void {
            const this: *@This() = @fieldParentPtr(@This(), "element", element);

            const input_fields = std.meta.fields(InputFields(Data));
            inline for (input_fields) |input_field| {
                @field(this.inputs, input_field.name).element.release();
            }
            this.element.manager.gpa.destroy(this);
        }

        pub fn layout(element: *Element, min_size: [2]f32, max_size: [2]f32) [2]f32 {
            const this: *@This() = @fieldParentPtr(@This(), "element", element);
            _ = min_size;

            var pos = [2]f32{ 0, 0 };

            const input_fields = std.meta.fields(InputFields(Data));
            inline for (input_fields) |input_field| {
                const name_size = this.element.manager.font.textSize(input_field.name, 1);
                pos[0] = @max(pos[0], name_size[0]);
            }

            var max_element_width: f32 = 0;
            inline for (input_fields) |input_field| {
                const input = &@field(this.inputs, input_field.name).element;

                input.rect.pos = pos;
                input.rect.size = input.layout(
                    .{ 0, this.element.manager.font.lineHeight },
                    .{
                        max_size[0] - pos[0],
                        max_size[1] - pos[1],
                    },
                );

                max_element_width = @max(max_element_width, input.rect.size[0]);
                pos[1] += input.rect.size[1];
            }

            const width = pos[0] + max_element_width;

            this.submit_button.element.rect.size = this.submit_button.element.layout(.{ 0, 0 }, .{ 0, 0 });
            this.submit_button.element.rect.pos = .{
                width - this.submit_button.element.rect.size[0],
                pos[1],
            };
            pos[1] += this.submit_button.element.rect.size[1];

            return .{ width, pos[1] };
        }

        fn render(element: *Element, canvas: *Canvas, rect: Rect) void {
            const this: *@This() = @fieldParentPtr(@This(), "element", element);

            const input_fields = std.meta.fields(InputFields(Data));
            var max_y: f32 = 0;
            inline for (input_fields) |input_field| {
                const input = &@field(this.inputs, input_field.name).element;

                canvas.writeText(input_field.name, .{
                    .pos = .{ rect.pos[0], rect.pos[1] + input.rect.pos[1] + input.rect.size[1] / 2 },
                    .baseline = .middle,
                });

                input.render(canvas, .{
                    .pos = .{
                        rect.pos[0] + input.rect.pos[0],
                        rect.pos[1] + input.rect.pos[1],
                    },
                    .size = input.rect.size,
                });

                max_y = @max(max_y, input.rect.pos[1] + input.rect.size[1]);
            }

            this.submit_button.element.render(canvas, .{
                .pos = .{
                    rect.pos[0] + this.submit_button.element.rect.pos[0],
                    rect.pos[1] + this.submit_button.element.rect.pos[1],
                },
                .size = this.submit_button.element.rect.size,
            });
        }

        fn onHover(element: *Element, pos: [2]f32) ?*Element {
            const this: *@This() = @fieldParentPtr(@This(), "element", element);

            const input_fields = std.meta.fields(InputFields(Data));
            inline for (input_fields) |input_field| {
                const input = &@field(this.inputs, input_field.name).element;

                if (input.rect.contains(pos)) {
                    if (input.onHover(.{ pos[0] - input.rect.pos[0], pos[1] - input.rect.pos[1] })) |hovered| {
                        return hovered;
                    }
                }
            }

            if (this.submit_button.element.rect.contains(pos)) {
                if (this.submit_button.element.onHover(.{ pos[0] - this.submit_button.element.rect.pos[0], pos[1] - this.submit_button.element.rect.pos[1] })) |hovered| {
                    return hovered;
                }
            }

            return null;
        }

        fn onClick(element: *Element, event: ui.event.Click) bool {
            const this: *@This() = @fieldParentPtr(@This(), "element", element);

            const input_fields = std.meta.fields(InputFields(Data));
            inline for (input_fields) |input_field| {
                const input = &@field(this.inputs, input_field.name).element;

                if (input.rect.contains(event.pos)) {
                    if (input.onClick(event.translate(.{ -input.rect.pos[0], -input.rect.pos[1] }))) {
                        return true;
                    }
                }
            }

            if (this.submit_button.element.rect.contains(event.pos)) {
                if (this.submit_button.element.onClick(event.translate(.{ -this.submit_button.element.rect.pos[0], -this.submit_button.element.rect.pos[1] }))) {
                    return true;
                }
            }

            return false;
        }

        fn onSubmitButtonClicked(userdata: ?*anyopaque, button: *ui.Button) void {
            const this: *@This() = @ptrCast(@alignCast(userdata.?));
            _ = button;

            this.submit();
        }

        fn submit(this: *@This()) void {
            var data: Data = undefined;

            const data_fields = std.meta.fields(Data);
            const input_fields = std.meta.fields(InputFields(Data));
            inline for (input_fields, data_fields) |input_field, data_field| {
                const input_element = @field(this.inputs, input_field.name);
                const data_ptr = &@field(data, input_field.name);
                switch (data_field.type) {
                    []const u8 => data_ptr.* = input_element.text.items,
                    f32 => data_ptr.* = input_element.number,
                    else => @compileError("Unsupported type " ++ @typeName(data_field.type) ++ " in InputFields."),
                }
            }

            if (this.on_submit_fn) |on_submit_fn| {
                on_submit_fn(this.userdata, data);
            }
        }

        fn onNumberFieldChanged(userdata: ?*anyopaque, field: *ui.NumberField) void {
            const this: *@This() = @ptrCast(@alignCast(userdata.?));
            _ = field;

            if (this.on_change_fn) |on_change_fn| {
                on_change_fn(this.userdata, this);
            }
        }

        fn onTextFieldEnter(userdata: ?*anyopaque, field: *ui.TextField) void {
            const this: *@This() = @ptrCast(@alignCast(userdata.?));

            const input_fields = std.meta.fields(InputFields(Data));
            const index = inline for (input_fields, 0..) |input_field, index| {
                const input = @field(this.inputs, input_field.name);
                if (&input.element == &field.element) {
                    break index;
                }
            } else input_fields.len;

            if (index == input_fields.len - 1) {
                this.submit();
            } else {
                const next_input: ?*Element = inline for (input_fields, 0..) |input_field, i| {
                    if (i == index + 1) {
                        break &@field(this.inputs, input_field.name).element;
                    }
                } else null;
                this.element.manager.focused_element = next_input;
            }
        }
    };
}

const Rect = ui.Rect;
const Element = ui.Element;
const ui = @import("../ui.zig");
const Canvas = @import("../Canvas.zig");
const utils = @import("utils");
const std = @import("std");
