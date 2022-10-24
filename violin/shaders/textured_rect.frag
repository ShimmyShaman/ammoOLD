#version 450
// #extension GL_ARB_separate_shader_objects : enable

layout(location = 0) out vec4 out_color;

layout(location = 2) in vec4 in_tint;
layout(location = 3) in vec2 in_uv;

layout(binding = 2) uniform sampler2D texture_sampler;

void main() {
    out_color = texture(texture_sampler, in_uv) * in_tint;
    // out_color = texture(texture_sampler, in_uv);
    // out_color = vec4(1.0, 0.3, 0.3, 1.0);
}