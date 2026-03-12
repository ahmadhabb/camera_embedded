#version 460 core
#include <flutter/runtime_effect.glsl>

// 0: AnypointM1, 1: AnypointM2, 2: PanoramaCar, 3: PanoramaTube
uniform float uMode;
uniform vec2  uResolution;  // Ukuran widget di layar
uniform vec4  uControl;     // x: Alpha/Pitch, y: Beta/Yaw, z: Zoom, w: AlphaMax
uniform vec2  uMoilSize;    // Resolusi asli gambar fisheye
uniform vec2  uMoilCenter;  // iCx, iCy
uniform float uCpRatio;     // Calibration ratio
uniform float p0, p1, p2, p3, p4, p5;
uniform sampler2D uTexture;

out vec4 fragColor;

#define PI 3.14159265358979323846

// ─────────────────────────────────────────────
// MOIL POLYNOMIAL
// ─────────────────────────────────────────────
float calculateRho(float alpha) {
    float a2 = alpha * alpha;
    float a3 = a2 * alpha;
    float a4 = a3 * alpha;
    float a5 = a4 * alpha;
    float a6 = a5 * alpha;
    return (p0*a6 + p1*a5 + p2*a4 + p3*a3 + p4*a2 + p5*alpha) * uCpRatio;
}

// ─────────────────────────────────────────────
// BICUBIC SAMPLING (Mitchell-Netravali B=1/3 C=1/3)
// Kualitas lebih halus dari bilinear bawaan,
// terutama saat zoom in atau area detail tinggi.
// ─────────────────────────────────────────────
float mitchellNetravali(float x) {
    const float B = 1.0 / 3.0;
    const float C = 1.0 / 3.0;
    x = abs(x);
    if (x < 1.0) {
        return ((12.0 - 9.0*B - 6.0*C)*x*x*x
              + (-18.0 + 12.0*B + 6.0*C)*x*x
              + (6.0 - 2.0*B)) / 6.0;
    } else if (x < 2.0) {
        return ((-B - 6.0*C)*x*x*x
              + (6.0*B + 30.0*C)*x*x
              + (-12.0*B - 48.0*C)*x
              + (8.0*B + 24.0*C)) / 6.0;
    }
    return 0.0;
}

vec4 sampleBicubic(vec2 uv) {
    vec2 texel = 1.0 / uMoilSize;
    vec2 coord = uv * uMoilSize - 0.5;
    vec2 fxy   = fract(coord);
    coord      = floor(coord);

    vec4 xcubic = vec4(
        mitchellNetravali(fxy.x + 1.0),
        mitchellNetravali(fxy.x),
        mitchellNetravali(1.0 - fxy.x),
        mitchellNetravali(2.0 - fxy.x)
    );
    vec4 ycubic = vec4(
        mitchellNetravali(fxy.y + 1.0),
        mitchellNetravali(fxy.y),
        mitchellNetravali(1.0 - fxy.y),
        mitchellNetravali(2.0 - fxy.y)
    );

    vec4 result = vec4(0.0);
    for (int j = 0; j < 4; j++) {
        for (int i = 0; i < 4; i++) {
            vec2 sUV = (coord + vec2(float(i) - 1.0, float(j) - 1.0) + 0.5) * texel;
            sUV = clamp(sUV, texel * 0.5, 1.0 - texel * 0.5);
            result += texture(uTexture, sUV) * xcubic[i] * ycubic[j];
        }
    }
    return result;
}

// ─────────────────────────────────────────────
// CHROMATIC ABERRATION
// Simulasi dispersi warna lensa fisheye.
// Channel R dan B di-sample dari posisi UV
// yang sedikit berbeda dari center.
// strength ~0.002 = subtle, ~0.006 = kuat
// ─────────────────────────────────────────────
vec4 sampleWithAberration(vec2 uv) {
    const float strength = 0.0025;
    vec2 dir = uv - 0.5;

    vec2 uvR = clamp(uv + dir * strength,        0.0, 1.0);
    vec2 uvB = clamp(uv - dir * strength,        0.0, 1.0);

    float r = sampleBicubic(uvR).r;
    float g = sampleBicubic(uv).g;
    float b = sampleBicubic(uvB).b;
    return vec4(r, g, b, 1.0);
}

// ─────────────────────────────────────────────
// SMOOTH BOUNDARY
// Anti-alias tepi area valid fisheye.
// Tidak hard-cut hitam — fade halus ~2px.
// ─────────────────────────────────────────────
float boundaryAlpha(vec2 texCoord) {
    vec2  edge       = min(texCoord, 1.0 - texCoord);
    float dist       = min(edge.x, edge.y);
    float fadePixels = 3.0 / min(uMoilSize.x, uMoilSize.y);
    return smoothstep(0.0, fadePixels, dist);
}

// ─────────────────────────────────────────────
// VIGNETTE
// Gradasi gelap natural dari tepi layar
// — seperti karakteristik lensa nyata.
// ─────────────────────────────────────────────
float vignette(vec2 uvScreen) {
    vec2  d = uvScreen - 0.5;
    float v = 1.0 - dot(d, d) * 1.8;
    return clamp(pow(v, 3.0), 0.0, 1.0);
}

// ─────────────────────────────────────────────
// MAIN
// ─────────────────────────────────────────────
void main() {
    vec2 fragCoord = FlutterFragCoord().xy;

    float sourceX = 0.0;
    float sourceY = 0.0;

    const float PCT_W      = 1.27;
    const float PCT_H      = 1.27;
    const float FOCAL_ZOOM = 250.0;

    // ── MODE 0 & 1: ANYPOINT ─────────────────
    if (uMode <= 1.5) {
        float dcx = uResolution.x * 0.5;
        float dcy = uResolution.y * 0.5;

        float alphaOffset = uControl.x * (PI / 180.0);
        float betaOffset  = (uControl.y + (uMode < 0.5 ? 180.0 : 0.0)) * (PI / 180.0);
        float zoom        = uControl.z;

        float tx, ty, tz;

        if (uMode < 0.5) { // AnyPoint M1
            float wCB    = PCT_W * cos(betaOffset);
            float hCASB  = PCT_H * cos(alphaOffset) * sin(betaOffset);
            float fZSASB = FOCAL_ZOOM * zoom * sin(alphaOffset) * sin(betaOffset);
            float wSB    = PCT_W * sin(betaOffset);
            float hCACB  = PCT_H * cos(alphaOffset) * cos(betaOffset);
            float fZSACB = FOCAL_ZOOM * zoom * sin(alphaOffset) * cos(betaOffset);
            float hSA    = PCT_H * sin(alphaOffset);
            float fZCA   = FOCAL_ZOOM * zoom * cos(alphaOffset);

            tx = (fragCoord.x - dcx) * wCB  - (fragCoord.y - dcy) * hCASB + fZSASB;
            ty = (fragCoord.x - dcx) * wSB  + (fragCoord.y - dcy) * hCACB - fZSACB;
            tz = (fragCoord.y - dcy) * hSA  + fZCA;
        } else { // AnyPoint M2
            float wCB    = PCT_W * cos(betaOffset);
            float hSASB  = PCT_H * sin(alphaOffset) * sin(betaOffset);
            float fZCASB = FOCAL_ZOOM * zoom * cos(alphaOffset) * sin(betaOffset);
            float hCA    = PCT_H * cos(alphaOffset);
            float fZSA   = FOCAL_ZOOM * zoom * sin(alphaOffset);
            float wSB    = PCT_W * sin(betaOffset);
            float hSACB  = PCT_H * sin(alphaOffset) * cos(betaOffset);
            float fZCACB = FOCAL_ZOOM * zoom * cos(alphaOffset) * cos(betaOffset);

            tx = -((fragCoord.x - dcx) * wCB  + (fragCoord.y - dcy) * hSASB + fZCASB);
            ty = -((fragCoord.y - dcy) * hCA  - fZSA);
            tz = -(fragCoord.x - dcx) * wSB   + (fragCoord.y - dcy) * hSACB + fZCACB;
        }

        float alpha = atan(sqrt(tx*tx + ty*ty), tz);
        float beta  = atan(ty, tx);
        float rho   = calculateRho(alpha);
        sourceX = uMoilCenter.x - rho * cos(beta);
        sourceY = uMoilCenter.y - rho * sin(beta);
    }

    // ── MODE 2: PANORAMA CAR ─────────────────
    else if (uMode < 2.5) {
        float alphaMax = uControl.w * (PI / 180.0);
        float iC_alpha = uControl.x * (PI / 180.0);
        float iC_beta  = -uControl.y * (PI / 180.0);

        float kx = sin(iC_alpha) * cos(iC_beta);
        float ky = sin(iC_alpha) * sin(iC_beta);
        float kz = cos(iC_alpha);

        float ing_alpha    = (fragCoord.y / uResolution.y) * alphaMax;
        float target_alpha = iC_alpha + ing_alpha;

        float Vx = sin(target_alpha) * cos(iC_beta);
        float Vy = sin(target_alpha) * sin(iC_beta);
        float Vz = cos(target_alpha);

        float kxa_x = ky*Vz - kz*Vy;
        float kxa_y = kz*Vx - kx*Vz;
        float kxa_z = kx*Vy - ky*Vx;
        float k_a   = kx*Vx + ky*Vy + kz*Vz;

        float ing_beta = (fragCoord.x / uResolution.x) * 2.0 * PI;
        float cB = cos(ing_beta);
        float sB = sin(ing_beta);

        float v_rot_x = cB*Vx + kxa_x*sB + kx*k_a*(1.0 - cB);
        float v_rot_y = cB*Vy + kxa_y*sB + ky*k_a*(1.0 - cB);
        float v_rot_z = cB*Vz + kxa_z*sB + kz*k_a*(1.0 - cB);

        float f_alpha = atan(sqrt(v_rot_x*v_rot_x + v_rot_y*v_rot_y), v_rot_z);
        float f_beta  = (PI / 2.0) - atan(v_rot_y, v_rot_x);
        float rho     = calculateRho(f_alpha);

        sourceX = uMoilCenter.x - rho * cos(f_beta);
        sourceY = uMoilCenter.y - rho * sin(f_beta);
    }

    // ── MODE 3: PANORAMA TUBE ────────────────
    else if (uMode < 3.5) {
        float aMax = uControl.w;
        float aMin = uControl.x;
        float d2r  = PI / 180.0;
        float r2d  = 180.0 / PI;

        float z0 = tan((90.0 - aMin) * d2r);
        float z1 = tan((90.0 - aMax) * d2r);
        float bH = (z0 - z1) / uResolution.y;

        float alpha = (90.0 - atan(z0 - bH * fragCoord.y) * r2d) * d2r;
        float beta  = (PI / 2.0) - ((fragCoord.x / uResolution.x) * 2.0 * PI);

        float rho = calculateRho(alpha);
        sourceX = uMoilCenter.x - rho * cos(beta);
        sourceY = uMoilCenter.y - rho * sin(beta);
    }

    // ── FINAL SAMPLING & POST-PROCESS ────────
    vec2 texCoord = vec2(sourceX, sourceY) / uMoilSize;

    // Out-of-bounds → hitam solid
    if (texCoord.x < 0.0 || texCoord.x > 1.0 ||
        texCoord.y < 0.0 || texCoord.y > 1.0) {
        fragColor = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }

    // Bicubic sampling + chromatic aberration
    vec4 col = sampleWithAberration(texCoord);

    // FIX WARNA: swap R↔B (kamera output BGRA bukan RGBA)
    col = vec4(col.b, col.g, col.r, col.a);

    // Smooth boundary fade di tepi area valid
    col.rgb *= boundaryAlpha(texCoord);

    // Vignette (35% intensity — natural, tidak berlebihan)
    vec2 uvScreen = fragCoord / uResolution;
    col.rgb = mix(col.rgb, col.rgb * vignette(uvScreen), 0.35);

    // Contrast boost ringan (+5%)
    col.rgb = (col.rgb - 0.5) * 1.05 + 0.5;

    // Saturation boost ringan (+8%)
    float lum = dot(col.rgb, vec3(0.2126, 0.7152, 0.0722));
    col.rgb = mix(vec3(lum), col.rgb, 1.08);

    fragColor = texture(uTexture, texCoord);
}