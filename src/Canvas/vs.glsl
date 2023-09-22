#version 300 es
layout(location=0) in vec3 point_xyz;
layout(location=1) in vec2 point_uv;
layout(location=2) in vec4 point_tint;
layout(location=3) in uint point_shape;
layout(location=4) in vec3 point_bary;

uniform mat4 projection;

out vec2 uv;
out vec4 tint;
flat out uint shape;
out vec3 bary;
out vec3 local_pos;

void main() {
    uv = point_uv;
    tint = point_tint;
    local_pos = point_xyz;
    gl_Position = projection * vec4(point_xyz, 1.0);
    shape = point_shape;
    bary = point_bary;
}
