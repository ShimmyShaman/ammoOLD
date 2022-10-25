#version 450
// #extension GL_ARB_separate_shader_objects : enable

layout (binding = 1) uniform UBO1 {
    vec2 offset;
    vec2 scale;
    vec4 color;
    vec4 uv_rect;
} ubo;

layout(location = 0) in vec2 in_position;
layout(location = 1) in vec2 in_uv;

layout(location = 2) out vec4 out_tint;
layout(location = 3) out vec2 out_uv;

void main() {
    gl_Position = vec4(2.0 * ubo.offset - 1.0 + 2.0 * in_position * ubo.scale, 0.0, 1.0);
    
    out_uv = ubo.uv_rect.xy + in_uv * ubo.uv_rect.zw;
    out_tint = ubo.color;
}