#version 450
// #extension GL_ARB_separate_shader_objects : enable

layout (std140, binding = 0) uniform UBO0 {
  mat4 mvp;
} world;

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec2 in_tex_coord;

layout(location = 1) out vec2 frag_tex_coord;

void main() {
  gl_Position = world.mvp * vec4(in_position, 1.0);
  // gl_Position.y = -gl_Position.y;
  frag_tex_coord = in_tex_coord;

  // gl_Position = vec4(in_position.yx, 0.0, 0.0);
  // // gl_Position.xy *= element.scale.xy;
  // // gl_Position.xy += element.offset.xy;
  // frag_tex_coord = in_tex_coord;
}