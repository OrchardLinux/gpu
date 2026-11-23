#version 450
// SPDX-License-Identifier: MIT
// a cube map at direction ma + s * sa + t * ta, s and t the rectangle's uv in [-1, 1] (one face per draw)
layout(set = 0, binding = 0) uniform U { vec4 ma; vec4 sa; vec4 ta; } u;
layout(set = 0, binding = 1) uniform samplerCube tex;
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 c;
void main() {
   vec2 st = uv * 2.0 - 1.0;
   c = texture(tex, u.ma.xyz + st.x * u.sa.xyz + st.y * u.ta.xyz);
}
