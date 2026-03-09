#version 460 core
#include <flutter/runtime_effect.glsl>

precision highp float;

uniform float iTime;
uniform vec2 iResolution;

out vec4 fragColor;

float julia(vec2 uv, vec2 c) {
    const float maxSteps = 400.0;
    for (float i = 0; i < maxSteps; i++) {
        uv = vec2(uv.x * uv.x - uv.y * uv.y + c.x,
                  2.0 * uv.x * uv.y + c.y);
        if (length(uv) > 2.0) return i / maxSteps;
    }
    return 1.0;
}

void main() {
    vec2 fragCoord = FlutterFragCoord().xy;
    vec2 texCoord = fragCoord / iResolution;
    
    // Exact mapping from PyQt6: 0,0 is center, Y matches video orientation
    vec2 uv = vec2(-1.0 + 2.0 * texCoord.x, -1.0 + 2.0 * texCoord.y);
    float aspect = iResolution.x / iResolution.y;
    uv.x *= aspect;

    float zoom = pow(0.5, -1.0 + 15.0 * (0.5 + 0.5 * sin(iTime * 0.80 - 3.14159265)));
    vec2 c = (uv * zoom) + vec2(-0.51, -0.61351);
    
    float f = julia(vec2(0.0, 0.0), c);
    
    // Color mapping mirrored from Python math
    vec3 fractalColor = vec3(1.0 - uv.x, 1.0 - uv.y, 1.0) * pow(f, 0.5);
    
    fragColor = vec4(fractalColor, f);
}