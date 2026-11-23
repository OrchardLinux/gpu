#version 450
// SPDX-License-Identifier: MIT
// the smoke triangle's vertex shader: the position passed through
layout(location = 0) in vec4 pos;
void main() { gl_Position = pos; }
