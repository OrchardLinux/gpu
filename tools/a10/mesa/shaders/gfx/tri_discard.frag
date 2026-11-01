#version 450
layout(location = 0) in vec4 v_col;
layout(location = 0) out vec4 o;
void main()
{
	if (v_col.r > 0.5)
		discard;
	o = v_col;
}
