#version 450
// SPDX-License-Identifier: MIT
layout(location = 0) in vec4 vcol;
layout(location = 0) out vec4 c;
void main() { c = vcol; }
