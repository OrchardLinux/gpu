#version 450
layout(location = 0) in vec4 v_col;
layout(location = 0) out vec4 o;
layout(set = 0, binding = 0) uniform sampler2D t;
void main()
{
	o = texture(t, v_col.xy);
}
