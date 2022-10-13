#version 450
// #extension GL_ARB_separate_shader_objects : enable

// layout (binding = 1) uniform UBO1 {
//     vec2 offset;
//     vec2 scale;
// } element;

layout(location = 0) in vec2 in_position;
layout(location = 1) in vec2 in_tex_coord;

layout(location = 1) out vec2 frag_tex_coord;

void main() {
    gl_Position = vec4(in_position, 0.0, 1.0);
    // gl_Position.xy *= element.scale.xy;
    // gl_Position.xy += element.offset.xy;
    frag_tex_coord = in_tex_coord;
}