#version 300 es

precision mediump float;

in vec2 uv;
in vec4 tint;
in vec3 local_pos;
flat in uint shape;
in vec3 bary;

uniform sampler2D texture_handle;
uniform sampler2D colormap_handle;

out vec4 color;

void main() {
    switch (shape) {
        case 0u:
            color = tint * texture(texture_handle, uv);
            break;
        case 1u:
            vec2 circle_pos = vec2(floor(local_pos.x) - bary.x, floor(local_pos.y) - bary.y);
            float circle_distance = sqrt(circle_pos.x * circle_pos.x + circle_pos.y * circle_pos.y);
            if ((bary.z > 0.0 && circle_distance >= bary.z) || (bary.z < 0.0 && circle_distance <= -bary.z)) {
                discard;
            }
            color = tint * texture(texture_handle, uv);
            break;
        case 2u:
            float min_value = bary.x;
            float max_value = bary.y;
            float value = texture(texture_handle, uv).a;
            if (value < min_value) {
                discard;
            } else if (value > max_value) {
                color = vec4(1,0,0,1);
            } else {
                float colormap_index = (log(value) - log(min_value)) / (log(max_value) - log(min_value));
                color = texture(colormap_handle, vec2(colormap_index, 0));
            }
            break;
        default:
            color = vec4(1.0, 0.0, 0.0, 1.0);
    }
}
