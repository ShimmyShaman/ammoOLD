#version 450
// #extension GL_ARB_separate_shader_objects : enable

layout (binding = 1) uniform UBO1 {
    vec2 offset;
    vec2 scale;
    vec4 color;
} spec;

layout(location = 0) in vec2 in_position;

layout(location = 1) out vec4 out_color;

void main() {
    gl_Position = vec4(in_position, 0.0, 1.0);
    out_color = spec.color;
}