#version 450
// #extension GL_ARB_separate_shader_objects : enable

layout(location = 0) out vec4 out_color;

layout(location = 1) in vec3 in_color;


void main() {
    out_color = vec4(in_color, 1.0);
	// outColor = vec4(fragTexCoord.x, fragTexCoord.y, 0.2, 1.0);
    // outColor = vec4(1.0, 0.0, 0.0, 1.0);
}