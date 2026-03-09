#version 460 core
#include <flutter/runtime_effect.glsl>

// 0: AnypointM1, 1: AnypointM2, 2: PanoramaCar, 3: PanoramaTube, 4: MapsPanoramaM_Rt
uniform float uMode; 
uniform vec2 uResolution; // Ukuran Widget di Layar
uniform vec4 uControl;    // x: Alpha/Pitch, y: Beta/Yaw, z: Zoom, w: AlphaMax
uniform vec2 uMoilSize;   // Ukuran asli gambar fisheye (misal 2592, 1944)
uniform vec2 uMoilCenter; // iCx, iCy (sudah dikali ratio)
uniform float uCpRatio;   // Calibration Ratio
uniform float p0, p1, p2, p3, p4, p5; // Polinomial
uniform sampler2D uTexture;

out vec4 fragColor;

#define PI 3.14159265358979

// Fungsi Polinomial Fisheye Moil
float calculateRho(float alpha) {
    float a2 = alpha * alpha;
    float a3 = a2 * alpha;
    float a4 = a3 * alpha;
    float a5 = a4 * alpha;
    float a6 = a5 * alpha;
    return (p0 * a6 + p1 * a5 + p2 * a4 + p3 * a3 + p4 * a2 + p5 * alpha) * uCpRatio;
}

void main() {
    vec2 fragCoord = FlutterFragCoord().xy;
    
    // Output Koordinat
    float sourceX = 0.0;
    float sourceY = 0.0;
    
    // Konstanta Fisik Moil
    float PCT_W = 1.27;
    float PCT_H = 1.27;
    float FOCAL_ZOOM = 250.0;

    // --- MODE 1 & 0: ANYPOINT (PERSPECTIVE) ---
    if (uMode <= 1.5) {
        float dcx = uResolution.x / 2.0;
        float dcy = uResolution.y / 2.0;
        
        float alphaOffset = uControl.x * (PI / 180.0);
        float betaOffset = (uControl.y + (uMode < 0.5 ? 180.0 : 0.0)) * (PI / 180.0);
        float zoom = uControl.z;

        float tx, ty, tz;

        if (uMode < 0.5) { // AnyPoint M1
            float wCB = PCT_W * cos(betaOffset);
            float hCASB = PCT_H * cos(alphaOffset) * sin(betaOffset);
            float fZSASB = FOCAL_ZOOM * zoom * sin(alphaOffset) * sin(betaOffset);
            float wSB = PCT_W * sin(betaOffset);
            float hCACB = PCT_H * cos(alphaOffset) * cos(betaOffset);
            float fZSACB = FOCAL_ZOOM * zoom * sin(alphaOffset) * cos(betaOffset);
            float hSA = PCT_H * sin(alphaOffset);
            float fZCA = FOCAL_ZOOM * zoom * cos(alphaOffset);

            tx = (fragCoord.x - dcx) * wCB - (fragCoord.y - dcy) * hCASB + fZSASB;
            ty = (fragCoord.x - dcx) * wSB + (fragCoord.y - dcy) * hCACB - fZSACB;
            tz = (fragCoord.y - dcy) * hSA + fZCA;
        } else { // AnyPoint M2
            float wCB = PCT_W * cos(betaOffset);
            float hSASB = PCT_H * sin(alphaOffset) * sin(betaOffset);
            float fZCASB = FOCAL_ZOOM * zoom * cos(alphaOffset) * sin(betaOffset);
            float hCA = PCT_H * cos(alphaOffset);
            float fZSA = FOCAL_ZOOM * zoom * sin(alphaOffset);
            float wSB = PCT_W * sin(betaOffset);
            float hSACB = PCT_H * sin(alphaOffset) * cos(betaOffset);
            float fZCACB = FOCAL_ZOOM * zoom * cos(alphaOffset) * cos(betaOffset);

            tx = -((fragCoord.x - dcx) * wCB + (fragCoord.y - dcy) * hSASB + fZCASB);
            ty = -((fragCoord.y - dcy) * hCA - fZSA);
            tz = -(fragCoord.x - dcx) * wSB + (fragCoord.y - dcy) * hSACB + fZCACB;
        }

        float alpha = atan(sqrt(tx * tx + ty * ty), tz);
        float beta = atan(ty, tx);
        float rho = calculateRho(alpha);
        sourceX = uMoilCenter.x - rho * cos(beta);
        sourceY = uMoilCenter.y - rho * sin(beta);
    } 
    
    // --- MODE 2: PANORAMA CAR ---
    else if (uMode < 2.5) {
        float alphaMax = uControl.w * (PI / 180.0);
        float iC_alpha = uControl.x * (PI / 180.0);
        float iC_beta = -uControl.y * (PI / 180.0);

        float kx = sin(iC_alpha) * cos(iC_beta);
        float ky = sin(iC_alpha) * sin(iC_beta);
        float kz = cos(iC_alpha);

        float ing_alpha = (fragCoord.y / uResolution.y) * alphaMax;
        float target_alpha = iC_alpha + ing_alpha;

        float Vx = sin(target_alpha) * cos(iC_beta);
        float Vy = sin(target_alpha) * sin(iC_beta);
        float Vz = cos(target_alpha);

        float kxa_x = ky * Vz - kz * Vy;
        float kxa_y = kz * Vx - kx * Vz;
        float kxa_z = kx * Vy - ky * Vx;
        float k_a = kx * Vx + ky * Vy + kz * Vz;

        float ing_beta = (fragCoord.x / uResolution.x) * 2.0 * PI;
        float cB = cos(ing_beta);
        float sB = sin(ing_beta);

        float v_rot_x = cB * Vx + kxa_x * sB + kx * k_a * (1.0 - cB);
        float v_rot_y = cB * Vy + kxa_y * sB + ky * k_a * (1.0 - cB);
        float v_rot_z = cB * Vz + kxa_z * sB + kz * k_a * (1.0 - cB);

        float f_alpha = atan(sqrt(v_rot_x * v_rot_x + v_rot_y * v_rot_y), v_rot_z);
        float f_beta = (PI / 2.0) - atan(v_rot_y, v_rot_x);
        float rho = calculateRho(f_alpha);
        
        sourceX = uMoilCenter.x - rho * cos(f_beta);
        sourceY = uMoilCenter.y - rho * sin(f_beta);
    }

    // --- MODE 3: PANORAMA TUBE ---
    else if (uMode < 3.5) {
        float aMax = uControl.w; // Misal 110
        float aMin = uControl.x; // Misal 10
        
        float d2r = PI / 180.0;
        float r2d = 180.0 / PI;

        float z0 = tan((90.0 - aMin) * d2r);
        float z1 = tan((90.0 - aMax) * d2r);
        float bH = (z0 - z1) / uResolution.y;

        float alpha = (90.0 - atan(z0 - bH * fragCoord.y) * r2d) * d2r;
        float beta = (PI / 2.0) - ((fragCoord.x / uResolution.x) * 2.0 * PI);
        
        float rho = calculateRho(alpha);
        sourceX = uMoilCenter.x - rho * cos(beta);
        sourceY = uMoilCenter.y - rho * sin(beta);
    }

    // Final Sampling
    vec2 texCoord = vec2(sourceX, sourceY) / uMoilSize;

    // Cegah Reflection dengan pengecekan bound yang ketat
    if (texCoord.x < 0.0 || texCoord.x > 1.0 || texCoord.y < 0.0 || texCoord.y > 1.0) {
        fragColor = vec4(0.0, 0.0, 0.0, 1.0);
    } else {
        fragColor = texture(uTexture, texCoord);
    }
}