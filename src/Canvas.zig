program: gl.Uint,
uniforms: UniformLocations,
current_texture: ?gl.Uint,
current_colormap: gl.Uint,
vertices: std.ArrayListUnmanaged(Vertex),
transform_stack: std.ArrayListUnmanaged([4][4]f32),

blank_texture: gl.Uint,
default_colormap: gl.Uint,
font: BitmapFont,
font_pages: std.AutoHashMapUnmanaged(u32, FontPage),

vbo: gl.Uint,

const Canvas = @This();

pub fn init(
    allocator: std.mem.Allocator,
    options: struct {
        vertex_buffer_size: usize = 16_384,
        transform_stack_size: usize = 128,
        default_colormap: []const [3]f32 = &@import("./Canvas/colormaps.zig").turbo_srgb,
    },
) !@This() {
    // Text shader
    const program = gl.createProgram();
    errdefer gl.deleteProgram(program);

    {
        const vs = gl.createShader(gl.VERTEX_SHADER);
        defer gl.deleteShader(vs);
        const vs_src = @embedFile("./Canvas/vs.glsl");
        gl.shaderSource(vs, 1, &[_][*:0]const u8{vs_src}, null);
        gl.compileShader(vs);

        var vertex_shader_status: gl.Int = undefined;
        gl.getShaderiv(vs, gl.COMPILE_STATUS, &vertex_shader_status);

        if (vertex_shader_status != gl.TRUE) {
            var shader_log: [1024:0]u8 = undefined;
            var shader_log_len: gl.Sizei = undefined;
            gl.getShaderInfoLog(vs, shader_log.len, &shader_log_len, &shader_log);
            std.debug.print("{s}:{} error compiling shader: {s}\n", .{ @src().file, @src().line, shader_log });
            return error.ShaderCompilation;
        }

        const fs = gl.createShader(gl.FRAGMENT_SHADER);
        defer gl.deleteShader(fs);
        const fs_src = @embedFile("./Canvas/fs.glsl");
        gl.shaderSource(fs, 1, &[_][*:0]const u8{fs_src}, null);
        gl.compileShader(fs);

        var fragment_shader_status: gl.Int = undefined;
        gl.getShaderiv(fs, gl.COMPILE_STATUS, &fragment_shader_status);

        if (fragment_shader_status != gl.TRUE) {
            var shader_log: [1024:0]u8 = undefined;
            var shader_log_len: gl.Sizei = undefined;
            gl.getShaderInfoLog(fs, shader_log.len, &shader_log_len, &shader_log);
            std.debug.print("{s}:{} error compiling shader: {s}\n", .{ @src().file, @src().line, shader_log });
            return error.ShaderCompilation;
        }

        gl.attachShader(program, vs);
        gl.attachShader(program, fs);
        defer {
            gl.detachShader(program, vs);
            gl.detachShader(program, fs);
        }

        gl.linkProgram(program);

        var program_status: gl.Int = undefined;
        gl.getProgramiv(program, gl.LINK_STATUS, &program_status);

        if (program_status != gl.TRUE) {
            var program_log: [1024:0]u8 = undefined;
            var program_log_len: gl.Sizei = undefined;
            gl.getProgramInfoLog(program, program_log.len, &program_log_len, &program_log);
            std.debug.print("{s}:{} error compiling program: {s}\n", .{ @src().file, @src().line, program_log });
            return error.ShaderCompilation;
        }
    }

    var vertices = try std.ArrayListUnmanaged(Vertex).initCapacity(allocator, options.vertex_buffer_size);
    errdefer vertices.deinit(allocator);

    var transform_stack = try std.ArrayListUnmanaged([4][4]f32).initCapacity(allocator, options.transform_stack_size);
    errdefer transform_stack.deinit(allocator);

    var blank_texture: gl.Uint = undefined;
    gl.genTextures(1, &blank_texture);
    errdefer gl.deleteTextures(1, &blank_texture);
    {
        const BLANK_IMAGE = [_][4]u8{
            .{ 0xFF, 0xFF, 0xFF, 0xFF },
        };

        gl.bindTexture(gl.TEXTURE_2D, blank_texture);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, std.mem.sliceAsBytes(&BLANK_IMAGE).ptr);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    }

    var font = try BitmapFont.parse(allocator, @embedFile("./Canvas/PressStart2P_8.fnt"));
    errdefer font.deinit();

    var font_pages = std.AutoHashMapUnmanaged(u32, FontPage){};
    errdefer font_pages.deinit(allocator);

    var page_name_iter = font.pages.iterator();
    while (page_name_iter.next()) |font_page| {
        const page_id = font_page.key_ptr.*;
        const page_name = font_page.value_ptr.*;

        const image_bytes = if (std.mem.eql(u8, page_name, "PressStart2P_8.png")) @embedFile("./Canvas/PressStart2P_8.png") else return error.FontPageImageNotFound;

        var font_image = try zigimg.Image.fromMemory(allocator, image_bytes);
        defer font_image.deinit();

        var page_texture: gl.Uint = undefined;
        gl.genTextures(1, &page_texture);
        errdefer gl.deleteTextures(1, &page_texture);

        gl.bindTexture(gl.TEXTURE_2D, page_texture);
        gl.texImage2D(
            gl.TEXTURE_2D,
            0,
            gl.RGBA,
            @as(gl.Sizei, @intCast(font_image.width)),
            @as(gl.Sizei, @intCast(font_image.width)),
            0,
            gl.RGBA,
            gl.UNSIGNED_BYTE,
            std.mem.sliceAsBytes(font_image.pixels.rgba32).ptr,
        );
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

        try font_pages.put(allocator, page_id, .{
            .texture = page_texture,
            .size = .{
                @as(f32, @floatFromInt(font_image.width)),
                @as(f32, @floatFromInt(font_image.height)),
            },
        });
    }

    var colormap_texture: gl.Uint = undefined;
    {
        gl.genTextures(1, &colormap_texture);
        errdefer gl.deleteTextures(1, &colormap_texture);
        {
            gl.bindTexture(gl.TEXTURE_2D, colormap_texture);
            gl.texImage2D(
                gl.TEXTURE_2D,
                0,
                gl.RGB,
                @intCast(options.default_colormap.len),
                1,
                0,
                gl.RGB,
                gl.FLOAT,
                std.mem.sliceAsBytes(options.default_colormap).ptr,
            );
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        }
    }

    var vbo: gl.Uint = undefined;
    gl.genBuffers(1, &vbo);

    const projection = gl.getUniformLocation(program, "projection");
    const texture = gl.getUniformLocation(program, "texture_handle");
    const colormap = gl.getUniformLocation(program, "colormap_handle");

    return .{
        .program = program,
        .uniforms = .{
            .projection = projection,
            .texture = texture,
            .colormap = colormap,
        },
        .current_texture = null,
        .current_colormap = colormap_texture,
        .vertices = vertices,
        .transform_stack = transform_stack,

        .blank_texture = blank_texture,
        .default_colormap = colormap_texture,
        .font = font,
        .font_pages = font_pages,

        .vbo = vbo,
    };
}

pub fn deinit(this: *@This(), allocator: std.mem.Allocator) void {
    gl.deleteProgram(this.program);
    this.vertices.deinit(allocator);
    this.transform_stack.deinit(allocator);
    this.font.deinit();

    var page_name_iter = this.font_pages.iterator();
    while (page_name_iter.next()) |entry| {
        gl.deleteTextures(1, &entry.value_ptr.*.texture);
    }
    this.font_pages.deinit(allocator);

    gl.deleteBuffers(1, &this.vbo);
}

pub const BeginOptions = struct {
    projection: [4][4]f32,
};

pub fn begin(this: *@This(), options: BeginOptions) void {
    this.transform_stack.shrinkRetainingCapacity(0);
    this.transform_stack.appendAssumeCapacity(options.projection);

    // TEXTURE_UNIT0
    gl.useProgram(this.program);
    gl.uniform1i(this.uniforms.texture, 0);
    gl.uniform1i(this.uniforms.colormap, 1);
    gl.uniformMatrix4fv(this.uniforms.projection, 1, gl.FALSE, &this.transform_stack.items[0][0]);

    this.vertices.shrinkRetainingCapacity(0);

    gl.enable(gl.BLEND);
    gl.disable(gl.DEPTH_TEST);
    gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    gl.activeTexture(gl.TEXTURE0);
}

/// Multiplies transform by the previous transform and pushes the resulting transform to the stack.
/// It then uploads the new transform. Will flush vertices using the current transform.
pub fn pushTransform(this: *@This(), transform: [4][4]f32) void {
    std.debug.assert(this.transform_stack.items.len > 0);
    if (this.vertices.items.len > 0) {
        this.flush();
    }
    const transform_multiplied = utils.mat4.mul(f32, this.transform_stack.items[this.transform_stack.items.len - 1], transform);
    this.transform_stack.appendAssumeCapacity(transform_multiplied);
    gl.uniformMatrix4fv(this.uniforms.projection, 1, gl.FALSE, &transform_multiplied[0]);
}

/// Pops the current transform and applies the previous transform. Will flush vertices using the
/// current transform.
pub fn popTransform(this: *@This()) void {
    std.debug.assert(this.transform_stack.items.len > 0);
    if (this.vertices.items.len > 0) {
        this.flush();
    }
    _ = this.transform_stack.pop();
    gl.uniformMatrix4fv(this.uniforms.projection, 1, gl.FALSE, &this.transform_stack.items[this.transform_stack.items.len - 1][0]);
}

pub const RectOptions = struct {
    pos: [2]f32,
    size: [2]f32,
    color: [4]u8 = .{ 0xFF, 0xFF, 0xFF, 0xFF },
    texture: ?gl.Uint = null,
    colormap: ?gl.Uint = null,
    /// The top left and bottom right coordinates
    uv: [2][2]f32 = .{ .{ 0, 0 }, .{ 1, 1 } },
    shape: ShapeOptions = .triangle,

    const ShapeOptions = union(Vertex.Shape) {
        triangle: void,
        circle: struct {
            center: [2]f32,
            radius: f32,
        },
        colormap: struct {
            min: f32,
            max: f32,
        },
    };
};

pub fn rect(this: *@This(), options: RectOptions) void {
    if (this.vertices.unusedCapacitySlice().len < 6) {
        this.flush();
    }
    if (!std.meta.eql(options.texture, this.current_texture) or (options.colormap != null and options.colormap.? != this.current_colormap)) {
        this.flush();
        this.current_texture = options.texture;
        this.current_colormap = options.colormap orelse this.current_colormap;
    }

    this.vertices.appendSliceAssumeCapacity(&.{
        // triangle 1
        .{
            .pos = options.pos,
            .uv = options.uv[0],
            .color = options.color,
            .shape = options.shape,
            .bary = switch (options.shape) {
                .triangle => .{ 0, 0, 0 },
                .circle => |c| .{ c.center[0], c.center[1], c.radius },
                .colormap => |c| .{ c.min, c.max, 0 },
            },
        },
        .{
            .pos = .{
                options.pos[0] + options.size[0],
                options.pos[1],
            },
            .uv = .{
                options.uv[1][0],
                options.uv[0][1],
            },
            .color = options.color,
            .shape = options.shape,
            .bary = switch (options.shape) {
                .triangle => .{ 0, 0, 0 },
                .circle => |c| .{ c.center[0], c.center[1], c.radius },
                .colormap => |c| .{ c.min, c.max, 0 },
            },
        },
        .{
            .pos = .{
                options.pos[0],
                options.pos[1] + options.size[1],
            },
            .uv = .{
                options.uv[0][0],
                options.uv[1][1],
            },
            .color = options.color,
            .shape = options.shape,
            .bary = switch (options.shape) {
                .triangle => .{ 0, 0, 0 },
                .circle => |c| .{ c.center[0], c.center[1], c.radius },
                .colormap => |c| .{ c.min, c.max, 0 },
            },
        },

        // triangle 2
        .{
            .pos = .{
                options.pos[0] + options.size[0],
                options.pos[1] + options.size[1],
            },
            .uv = options.uv[1],
            .color = options.color,
            .shape = options.shape,
            .bary = switch (options.shape) {
                .triangle => .{ 0, 0, 0 },
                .circle => |c| .{ c.center[0], c.center[1], c.radius },
                .colormap => |c| .{ c.min, c.max, 0 },
            },
        },
        .{
            .pos = .{
                options.pos[0],
                options.pos[1] + options.size[1],
            },
            .uv = .{
                options.uv[0][0],
                options.uv[1][1],
            },
            .color = options.color,
            .shape = options.shape,
            .bary = switch (options.shape) {
                .triangle => .{ 0, 0, 0 },
                .circle => |c| .{ c.center[0], c.center[1], c.radius },
                .colormap => |c| .{ c.min, c.max, 0 },
            },
        },
        .{
            .pos = .{
                options.pos[0] + options.size[0],
                options.pos[1],
            },
            .uv = .{
                options.uv[1][0],
                options.uv[0][1],
            },
            .color = options.color,
            .shape = options.shape,
            .bary = switch (options.shape) {
                .triangle => .{ 0, 0, 0 },
                .circle => |c| .{ c.center[0], c.center[1], c.radius },
                .colormap => |c| .{ c.min, c.max, 0 },
            },
        },
    });
}

pub const TriangleOptions = struct {
    pos: [3][2]f32,
    color: [4]u8 = [4]u8{ 0xFF, 0xFF, 0xFF, 0xFF },
    texture: ?gl.Uint = null,
    colormap: ?gl.Uint = null,
    /// The top left and bottom right coordinates
    uv: [3][2]f32 = .{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } },
    shape: Vertex.Shape = .triangle,
    bary: [3][3]f32 = .{ .{ -1, -1, 0 }, .{ 1, -1, 0 }, .{ -1, 1, 0 } },
};

pub fn triangle(this: *@This(), options: TriangleOptions) void {
    if (this.vertices.unusedCapacitySlice().len < 3) {
        this.flush();
    }
    if (!std.meta.eql(options.texture, this.current_texture) or (options.colormap != null and options.colormap.? != this.current_colormap)) {
        this.flush();
        this.current_texture = options.texture;
        this.current_colormap = options.colormap orelse this.current_colormap;
    }

    this.vertices.appendSliceAssumeCapacity(&.{
        .{
            .pos = options.pos[0],
            .uv = options.uv[0],
            .color = options.color,
            .shape = options.shape,
            .bary = options.bary[0],
        },
        .{
            .pos = options.pos[1],
            .uv = options.uv[1],
            .color = options.color,
            .shape = options.shape,
            .bary = options.bary[1],
        },
        .{
            .pos = options.pos[2],
            .uv = options.uv[2],
            .color = options.color,
            .shape = options.shape,
            .bary = options.bary[2],
        },
    });
}

pub const TextOptions = struct {
    pos: [2]f32,
    color: [4]u8 = .{ 0xFF, 0xFF, 0xFF, 0xFF },
    scale: f32 = 1,
    @"align": Align = .left,
    baseline: Baseline = .top,

    const Align = enum {
        left,
        center,
        right,
    };

    const Baseline = enum {
        top,
        middle,
        bottom,
    };
};

pub fn writeText(this: *@This(), text: []const u8, options: TextOptions) [2]f32 {
    const text_size = this.font.textSize(text, options.scale);

    var x: f32 = switch (options.@"align") {
        .left => options.pos[0],
        .center => options.pos[0] - text_size[0] / 2,
        .right => options.pos[0] - text_size[0],
    };
    var y: f32 = switch (options.baseline) {
        .top => options.pos[1],
        .middle => options.pos[1] - text_size[1] / 2,
        .bottom => options.pos[1] - text_size[1],
    };
    var text_writer = this.textWriter(.{
        .pos = .{ x, y },
        .scale = options.scale,
        .color = options.color,
    });
    text_writer.writer().writeAll(text) catch {};
    return text_writer.size;
}

pub fn printText(this: *@This(), comptime fmt: []const u8, args: anytype, options: TextOptions) [2]f32 {
    const text_size = this.font.fmtTextSize(fmt, args, options.scale);

    const x: f32 = switch (options.@"align") {
        .left => options.pos[0],
        .center => options.pos[0] - text_size[0] / 2,
        .right => options.pos[0] - text_size[0],
    };
    const y: f32 = switch (options.baseline) {
        .top => options.pos[1],
        .middle => options.pos[1] - text_size[1] / 2,
        .bottom => options.pos[1] - text_size[1],
    };

    var text_writer = this.textWriter(.{
        .pos = .{ x, y },
        .scale = options.scale,
        .color = options.color,
    });
    text_writer.writer().print(fmt, args) catch {};
    return text_writer.size;
}

pub fn end(this: *@This()) void {
    this.flush();
    this.transform_stack.shrinkRetainingCapacity(0);
}

pub fn textWriter(this: *@This(), options: TextWriter.Options) TextWriter {
    return TextWriter{
        .canvas = this,
        .options = options,
        .direction = 1,
        .current_pos = options.pos,
    };
}

pub const TextWriter = struct {
    canvas: *Canvas,
    options: Options,
    direction: f32,
    current_pos: [2]f32,
    size: [2]f32 = .{ 0, 0 },

    pub const Options = struct {
        pos: [2]f32 = .{ 0, 0 },
        color: [4]u8 = .{ 0xFF, 0xFF, 0xFF, 0xFF },
        scale: f32 = 1,
    };

    pub fn addCharacter(this: *@This(), character: u21) void {
        if (character == '\n') {
            this.current_pos[1] += this.canvas.font.lineHeight * this.options.scale;
            this.current_pos[0] = this.options.pos[0];

            this.size = .{
                @max(this.current_pos[0] - this.options.pos[0], this.size[0]),
                @max(this.current_pos[1] - this.options.pos[1] + this.canvas.font.lineHeight * this.options.scale, this.size[1]),
            };
            return;
        }
        const glyph = this.canvas.font.glyphs.get(character) orelse return;

        const xadvance = (glyph.xadvance * this.options.scale);
        const offset = [2]f32{
            glyph.offset[0] * this.options.scale,
            glyph.offset[1] * this.options.scale,
        };

        const font_page = this.canvas.font_pages.get(glyph.page) orelse return;

        this.canvas.rect(.{
            .pos = .{
                this.current_pos[0] + offset[0],
                this.current_pos[1] + offset[1],
            },
            .size = .{
                glyph.size[0] * this.options.scale,
                glyph.size[1] * this.options.scale,
            },
            .texture = font_page.texture,
            .uv = .{
                .{
                    glyph.pos[0] / font_page.size[0],
                    glyph.pos[1] / font_page.size[1],
                },
                .{
                    (glyph.pos[0] + glyph.size[0]) / font_page.size[0],
                    (glyph.pos[1] + glyph.size[1]) / font_page.size[1],
                },
            },
            .color = this.options.color,
        });

        this.current_pos[0] += this.direction * xadvance;
        this.size = .{
            @max(this.current_pos[0] - this.options.pos[0], this.size[0]),
            @max(this.current_pos[1] - this.options.pos[1] + this.canvas.font.lineHeight * this.options.scale, this.size[1]),
        };
    }

    pub fn addText(this: *@This(), text: []const u8) void {
        for (text) |char| {
            this.addCharacter(char);
        }
    }

    pub fn writer(this: *@This()) Writer {
        return Writer{
            .context = this,
        };
    }

    pub const Writer = std.io.Writer(*@This(), error{}, write);

    pub fn write(this: *@This(), bytes: []const u8) error{}!usize {
        this.addText(bytes);
        return bytes.len;
    }
};

pub fn line(this: *@This(), pos1: [2]f32, pos2: [2]f32, options: struct {
    width: f32 = 1,
    color: [4]u8 = .{ 0xFF, 0xFF, 0xFF, 0xFF },
}) void {
    if (this.vertices.unusedCapacitySlice().len <= 3 or this.current_texture != null) {
        this.flush();
        this.current_texture = null;
    }

    const half_width = options.width / 2;
    const half_length = utils.vec.magnitude(2, f32, .{
        pos2[0] - pos1[0],
        pos2[1] - pos1[1],
    }) / 2;

    const forward = utils.vec.normalize(2, f32, .{
        pos2[0] - pos1[0],
        pos2[1] - pos1[1],
    });
    const right = utils.vec.normalize(2, f32, .{
        forward[1],
        -forward[0],
    });
    const midpoint = [2]f32{
        (pos1[0] + pos2[0]) / 2,
        (pos1[1] + pos2[1]) / 2,
    };

    const back_left = [2]f32{
        midpoint[0] - half_length * forward[0] - half_width * right[0],
        midpoint[1] - half_length * forward[1] - half_width * right[1],
    };
    const back_right = [2]f32{
        midpoint[0] - half_length * forward[0] + half_width * right[0],
        midpoint[1] - half_length * forward[1] + half_width * right[1],
    };
    const fore_left = [2]f32{
        midpoint[0] + half_length * forward[0] - half_width * right[0],
        midpoint[1] + half_length * forward[1] - half_width * right[1],
    };
    const fore_right = [2]f32{
        midpoint[0] + half_length * forward[0] + half_width * right[0],
        midpoint[1] + half_length * forward[1] + half_width * right[1],
    };

    this.vertices.appendSliceAssumeCapacity(&.{
        .{
            .pos = back_left,
            .uv = .{ 0, 0 },
            .color = options.color,
            .shape = .triangle,
            .bary = .{ 0, 0, -1 },
        },
        .{
            .pos = fore_left,
            .uv = .{ 0, 0 },
            .color = options.color,
            .shape = .triangle,
            .bary = .{ 0, 0, -1 },
        },
        .{
            .pos = back_right,
            .uv = .{ 0, 0 },
            .color = options.color,
            .shape = .triangle,
            .bary = .{ 0, 0, 1 },
        },

        .{
            .pos = back_right,
            .uv = .{ 0, 0 },
            .color = options.color,
            .shape = .triangle,
            .bary = .{ 0, 0, 1 },
        },
        .{
            .pos = fore_left,
            .uv = .{ 0, 0 },
            .color = options.color,
            .shape = .triangle,
            .bary = .{ 0, 0, -1 },
        },
        .{
            .pos = fore_right,
            .uv = .{ 0, 0 },
            .color = options.color,
            .shape = .triangle,
            .bary = .{ 0, 0, 1 },
        },
    });
}

fn flush(this: *@This()) void {
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, this.current_texture orelse this.blank_texture);
    defer {
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D, 0);
    }

    gl.activeTexture(gl.TEXTURE1);
    gl.bindTexture(gl.TEXTURE_2D, this.current_colormap);
    defer {
        gl.activeTexture(gl.TEXTURE1);
        gl.bindTexture(gl.TEXTURE_2D, 0);
    }

    gl.bindBuffer(gl.ARRAY_BUFFER, this.vbo);
    defer gl.bindBuffer(gl.ARRAY_BUFFER, 0);
    gl.bufferData(gl.ARRAY_BUFFER, @as(gl.Sizeiptr, @intCast(this.vertices.items.len * @sizeOf(Vertex))), this.vertices.items.ptr, gl.STREAM_DRAW);

    gl.vertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), @as(?*const anyopaque, @ptrFromInt(@offsetOf(Vertex, "pos"))));
    gl.vertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), @as(?*const anyopaque, @ptrFromInt(@offsetOf(Vertex, "uv"))));
    gl.vertexAttribPointer(2, 4, gl.UNSIGNED_BYTE, gl.TRUE, @sizeOf(Vertex), @as(?*const anyopaque, @ptrFromInt(@offsetOf(Vertex, "color"))));
    gl.vertexAttribIPointer(3, 1, gl.UNSIGNED_BYTE, @sizeOf(Vertex), @as(?*const anyopaque, @ptrFromInt(@offsetOf(Vertex, "shape"))));
    gl.vertexAttribPointer(4, 3, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), @as(?*const anyopaque, @ptrFromInt(@offsetOf(Vertex, "bary"))));
    gl.enableVertexAttribArray(0);
    gl.enableVertexAttribArray(1);
    gl.enableVertexAttribArray(2);
    gl.enableVertexAttribArray(3);
    gl.enableVertexAttribArray(4);

    gl.useProgram(this.program);
    gl.drawArrays(gl.TRIANGLES, 0, @as(gl.Sizei, @intCast(this.vertices.items.len)));

    this.vertices.shrinkRetainingCapacity(0);
    this.current_texture = null;
}

const UniformLocations = struct {
    projection: c_int,
    texture: c_int,
    colormap: c_int,
};

const FontPage = struct {
    texture: gl.Uint,
    size: [2]f32,
};

const Vertex = struct {
    pos: [2]f32,
    uv: [2]f32,
    color: [4]u8,
    shape: Shape,
    /// barycentric coordinates
    bary: [3]f32,

    const Shape = enum(u8) {
        triangle = 0,
        circle = 1,
        colormap = 2,
    };
};

const std = @import("std");
const BitmapFont = @import("./Canvas/bitmap.zig").Font;
const gl = @import("gl");
const zigimg = @import("zigimg");
const utils = @import("utils");
