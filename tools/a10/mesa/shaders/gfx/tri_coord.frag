#version 450
layout(location = 0) in vec4 v_col;
layout(location = 0) out vec4 o;
void main()
{
	o = vec4(gl_FragCoord.xy / 64.0, v_col.b, 1.0);
}
