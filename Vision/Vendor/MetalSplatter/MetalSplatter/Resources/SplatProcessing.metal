#import "SplatProcessing.h"

// MARK: - Color Space Conversion

/// Converts sRGB color to linear color space.
/// This is needed because Metal with sRGB framebuffers expects linear input,
/// while SH evaluation produces sRGB output (matching the reference implementation).
inline half3 sRGBToLinear(half3 srgb) {
    // Using gamma 2.2 approximation (standard for 3DGS training)
    return pow(srgb, half3(2.2h));
}

// MARK: - Front-to-Back Particle Formation

// Value noise adapted from Spark's Splat Reveal Effects (MIT).
// Reference and license: SPEC-V084.md / Vendor/SparkRevealReference-LICENSE.txt.
inline float revealHash(float3 p) {
    p = fract(p * 0.3183099f + 0.1f) * 17.0f;
    return fract(p.x * p.y * p.z);
}

inline float revealNoise(float3 p) {
    float3 cell = floor(p);
    float3 f = fract(p);
    f = f * f * (3.0f - 2.0f * f);
    float x00 = mix(revealHash(cell), revealHash(cell + float3(1, 0, 0)), f.x);
    float x10 = mix(revealHash(cell + float3(0, 1, 0)), revealHash(cell + float3(1, 1, 0)), f.x);
    float x01 = mix(revealHash(cell + float3(0, 0, 1)), revealHash(cell + float3(1, 0, 1)), f.x);
    float x11 = mix(revealHash(cell + float3(0, 1, 1)), revealHash(cell + float3(1, 1, 1)), f.x);
    return mix(mix(x00, x10, f.y), mix(x01, x11, f.y), f.z);
}

// Rotate both centres and anisotropic Gaussian covariance for Spark's helix effects.
inline float3x3 revealRotation(float3 axis, float angle) {
    float c = cos(angle), s = sin(angle), t = 1.0f - c;
    float x = axis.x, y = axis.y, z = axis.z;
    return float3x3(float3(t*x*x+c, t*x*y+s*z, t*x*z-s*y),
                    float3(t*x*y-s*z, t*y*y+c, t*y*z+s*x),
                    float3(t*x*z+s*y, t*y*z-s*x, t*z*z+c));
}

// Adapted from Spark's Spread, Magic, Unroll and Twister, with bounded 0...1 timing.
// The captured model-space frame is shared by both eyes and remains fixed during a reversal.
inline void applyReveal(thread Splat &splat, Uniforms uniforms) {
    if (uniforms.revealEnabled == 0 || uniforms.revealProgress >= 1.0f) return;
    if (uniforms.revealProgress <= 0.0f) { splat.color.a = 0.0h; return; }

    float progress = uniforms.revealProgress;
    float3 p = float3(splat.position);
    float3 origin = float3(uniforms.revealOriginX, uniforms.revealOriginY, uniforms.revealOriginZ);
    // Pinchspace: unlock each original Gaussian by its distance from the captured fingertip.
    // The global growing transform preserves depth order; this branch never shifts a splat.
    if (uniforms.revealStyle == 5) {
        float dist = length(p - origin) / max(0.001f, uniforms.revealRadius);
        float grain = revealHash(p * 57.23f + float3(3.1f, 7.2f, 1.7f));
        float arrival = min(1.0f, dist) * (1.0f - uniforms.revealFrontWidth - 0.04f)
                        + 0.034f * grain;
        float phase = saturate((progress - arrival) / uniforms.revealFrontWidth);
        if (phase >= 1.0f) return;
        if (phase <= 0.0f) { splat.color.a = 0.0h; return; }
        float body = smoothstep(0.14f, 0.98f, phase);
        float ink = smoothstep(0.0f, 0.19f, phase);
        float sparkle = (1.0f - smoothstep(0.11f, 0.64f, phase)) * 0.31f;
        float3 base = clamp(float3(splat.color.rgb) * 0.2820948f + 0.5f, 0.0f, 1.0f);
        float peak = max(0.22f, max(base.r, max(base.g, base.b)));
        float3 lit = mix(base / peak * 0.92f, float3(1.0f, 0.97f, 0.92f), 0.27f);
        splat.color.rgb = mix(splat.color.rgb, half3((lit - 0.5f) / 0.2820948f), half(sparkle));
        splat.color.a *= half(ink);
        float scale = 0.06f + 0.94f * body;
        float seedRadius = uniforms.revealSeedRadius * (1.0f - body);
        float seedVariance = seedRadius * seedRadius;
        splat.covA = packed_half3(float3(splat.covA) * scale * scale + float3(seedVariance, 0, 0));
        splat.covB = packed_half3(float3(splat.covB) * scale * scale + float3(seedVariance, 0, seedVariance));
        return;
    }
    float3 forward = float3(uniforms.revealDirectionX, uniforms.revealDirectionY, uniforms.revealDirectionZ);
    float3 up = float3(uniforms.revealUpX, uniforms.revealUpY, uniforms.revealUpZ);
    float3 center = origin + forward * (0.5f * (uniforms.revealNearDepth + uniforms.revealFarDepth))
                          + up * (0.5f * (uniforms.revealLow + uniforms.revealHigh));
    float3 q = p - center;
    float height = dot(q, up);
    float3 radial = q - up * height;
    float radius = max(0.001f, uniforms.revealRadius);
    float radialPhase = saturate(length(radial) / radius);
    float heightPhase = saturate((dot(p - origin, up) - uniforms.revealLow) /
                                max(0.001f, uniforms.revealHigh - uniforms.revealLow));
    float grain = revealHash(p * 73.19f + float3(3.1f, 7.2f, 1.7f));
    float3 scatter = float3(grain,
        revealHash(p * 47.31f + float3(1.8f, 8.3f, 2.4f)),
        revealHash(p * 59.73f + float3(6.4f, 2.1f, 9.5f))) * 2.0f - 1.0f;
    float phase = 0;
    float growth = 0;
    float opacity = 0;
    float angle = 0;
    float3 position = p;

    if (uniforms.revealStyle == 2) {
        // Magic: angular seed reveal followed by an expanding noisy radial formation ring.
        float3 right = cross(up, forward);
        if (dot(right, right) < 0.0001f) right = cross(up, abs(up.x) < 0.9f ? float3(1,0,0) : float3(0,0,1));
        right = normalize(right);
        float3 tangent = normalize(cross(right, up));
        float angular = atan2(dot(radial, right), dot(radial, tangent)) / (2.0f * M_PI_F) + 0.5f;
        opacity = smoothstep(angular * 0.20f, angular * 0.20f + 0.03f, progress);
        phase = saturate((progress - 0.18f - radialPhase * 0.58f) / 0.24f);
        growth = smoothstep(0.0f, 1.0f, phase);
        float border = abs((progress - 0.18f) / 0.58f - radialPhase);
        float3 boundedQ = q * min(1.0f, radius / max(length(q), 0.001f));
        position -= boundedQ * (0.20f * exp(-20.0f * border) * (1.0f - growth));
        position += scatter * uniforms.revealParticleTravel * 2.0f * (1.0f - growth);
    } else {
        float arrival;
        if (uniforms.revealStyle == 3) {
            // Unroll: a vertical helix unwinds and expands out to the original scene.
            arrival = heightPhase * 0.70f + grain * 0.03f;
        } else if (uniforms.revealStyle == 4) {
            // Twister: radial weather front, with individual rise timing and a shrinking spin.
            arrival = radialPhase * 0.68f + grain * 0.04f;
        } else {
            // Spread: preserve Spark's two-stage scale growth, progressing near to far.
            float depthPhase = saturate((dot(p - origin, forward) - uniforms.revealNearDepth) /
                                        max(0.001f, uniforms.revealFarDepth - uniforms.revealNearDepth));
            float regional = revealNoise(p * uniforms.revealNoiseFrequency);
            arrival = depthPhase * (1.0f - uniforms.revealFrontWidth - 0.06f)
                    + 0.04f * regional + 0.02f * grain;
        }
        phase = saturate((progress - arrival) / uniforms.revealFrontWidth);
        if (phase <= 0.0f) { splat.color.a = 0.0h; return; }
        if (phase >= 1.0f) return;
        opacity = smoothstep(0.0f, 0.12f, phase);
        if (uniforms.revealStyle == 3) {
            growth = smoothstep(0.25f, 1.0f, phase);
            angle = (heightPhase * 8.0f - 4.0f) * M_PI_F * exp(-3.0f * phase) * (1.0f - phase);
            position = center + revealRotation(up, angle) * q * mix(0.2f, 1.0f, smoothstep(0.0f, 1.0f, phase));
        } else if (uniforms.revealStyle == 4) {
            float s = smoothstep(0.0f, 1.0f, phase);
            float rise = pow(s, 0.5f + 2.0f * grain);
            float h = max(0.25f, uniforms.revealHigh - uniforms.revealLow);
            float y = mix(-h * 0.65f, height, rise);
            float3 r = radial * mix(0.5f, 1.0f, rise);
            angle = progress * 8.0f * (1.0f - s) * 0.2f
                  + (y / h) * 20.0f * (1.0f - s) * exp(-length(r) / radius);
            position = center + revealRotation(up, angle) * r + up * y;
            growth = pow(s, 12.0f);
        } else {
            growth = max(0.2f * smoothstep(0.12f, 0.35f, phase), smoothstep(0.32f, 1.0f, phase));
            float remaining = 1.0f - smoothstep(0.15f, 1.0f, phase);
            position += (0.45f * scatter - 0.55f * forward) * uniforms.revealParticleTravel * remaining * remaining;
        }
    }

    // Preserve original colour; birth opacity is brief, the visible effect is particle motion/shape.
    splat.color.a *= half(opacity);
    float remaining = 1.0f - growth;
    float seedVariance = uniforms.revealSeedRadius * uniforms.revealSeedRadius * remaining * remaining;
    float3 a = float3(splat.covA), b = float3(splat.covB);
    float3x3 covariance = float3x3(a, float3(a.y, b.x, b.y), float3(a.z, b.y, b.z));
    if (uniforms.revealStyle >= 3) {
        float3x3 rotation = revealRotation(up, angle);
        covariance = rotation * covariance * transpose(rotation);
    }
    covariance *= growth * growth;
    covariance[0][0] += seedVariance;
    covariance[1][1] += seedVariance;
    covariance[2][2] += seedVariance;
    splat.covA = packed_half3(covariance[0]);
    splat.covB = packed_half3(covariance[1][1], covariance[2][1], covariance[2][2]);
    splat.position = packed_float3(position);
}

// Keep only rays that travel from the eye through the local Z=0 doorway into the digital world.
inline void applyPortal(thread Splat &splat, Uniforms uniforms) {
    if (uniforms.portalEnabled == 0) return;

    float3 camera = float3(uniforms.cameraPosition);
    float3 point = float3(splat.position);
    float denominator = point.z - camera.z;
    float coverage = 0.0f;

    // ML Sharp stores the photographed scene along +Z. After the model's X flip,
    // the viewer starts at local -Z and walks through the doorway toward +Z.
    if (camera.z < 0.0f && point.z > 0.0f && abs(denominator) > 0.00001f) {
        float t = -camera.z / denominator;
        if (t >= 0.0f && t <= 1.0f) {
            float2 hit = camera.xy + (point.xy - camera.xy) * t;
            float signedDistance = min(uniforms.portalHalfWidth - abs(hit.x),
                                       uniforms.portalHalfHeight - abs(hit.y - uniforms.portalCenterY));
            coverage = smoothstep(-uniforms.portalFeather, uniforms.portalFeather, signedDistance);
        }
    }

    // Crossing the doorway opens the whole scene; blend before the plane to avoid a hard pop.
    float entered = smoothstep(-0.25f, 0.0f, camera.z);
    coverage = max(coverage, entered);
    splat.color.a *= half(coverage);
}

// Native SPZ decoding flips Y/Z from the browser asset convention.
// Compute the artwork in the original asset axes, then map displacement back.
inline void applyArtwork(thread Splat &splat, Uniforms uniforms) {
    if (uniforms.artworkMode == 0) return;
    float3 nativePoint = float3(splat.position);
    float3 p = nativePoint * float3(1.0f, -1.0f, -1.0f);
    float3 delta = float3(0.0f);

    if (uniforms.artworkMode == 1) {
        float3 q = p * uniforms.artworkFrequency;
        float3 a = sin(float3(
            dot(q, float3(0.83f, 0.46f, 0.21f)),
            dot(q, float3(-0.31f, 0.79f, 0.55f)),
            dot(q, float3(0.45f, -0.26f, 0.88f)))
            + float3(0.0f, 2.1f, 4.2f));
        float3 b = sin(float3(
            dot(q * 2.2f, float3(1.37f, -0.52f, 0.72f)),
            dot(q * 2.2f, float3(0.61f, 1.21f, -0.43f)),
            dot(q * 2.2f, float3(-0.79f, 0.38f, 1.17f)))
            + float3(1.4f, 3.8f, 0.7f));
        float delay = 0.45f * sin(dot(p, float3(0.38f, 0.24f, -0.31f)));
        float localSin = uniforms.artworkCycleSin + delay * uniforms.artworkCycleCos;
        float localCos = uniforms.artworkCycleCos - delay * uniforms.artworkCycleSin;
        delta = 1.15f * (a * localSin + 0.7f * b * localCos) * uniforms.artworkAmount;
    } else if (uniforms.artworkMode == 2 && uniforms.artworkAge >= 0.0f) {
        float size = max(uniforms.artworkFragmentSize, 0.001f);
        float3 cell = floor(p / size);
        float3 center = (cell + 0.5f) * size;
        float3 origin = float3(uniforms.artworkOriginX, -uniforms.artworkOriginY,
                               -uniforms.artworkOriginZ);
        float distanceFromTouch = length(center - origin);
        float progress = clamp((uniforms.artworkAge -
                                distanceFromTouch / max(uniforms.artworkWaveSpeed, 0.001f)) /
                               max(uniforms.artworkDuration, 0.001f), 0.0f, 1.0f);
        float energy = 16.0f * progress * progress *
                       (1.0f - progress) * (1.0f - progress);
        float shock = smoothstep(0.0f, 0.12f, uniforms.artworkAge) *
                      (1.0f - smoothstep(0.0f, 0.5f,
                             abs(uniforms.artworkAge * uniforms.artworkWaveSpeed -
                                 distanceFromTouch)));
        float reach = 1.0f - smoothstep(uniforms.artworkMaxRadius - 0.5f,
                                        uniforms.artworkMaxRadius, distanceFromTouch);
        float motion = reach * (energy + 0.24f * shock);
        if (motion > 0.00001f) {
            float3 jitter = sin(float3(
                dot(cell, float3(1.37f, 2.11f, 0.73f)),
                dot(cell, float3(-0.89f, 1.53f, 2.47f)),
                dot(cell, float3(2.29f, -0.61f, 1.17f))));
            float3 outward = normalize(center - origin + 0.65f * jitter +
                                       float3(0.001f));
            delta = outward * uniforms.artworkStrength *
                    (0.85f + 0.15f * jitter.x) * motion;
        }
    }
    splat.position = packed_float3(nativePoint + delta * float3(1.0f, -1.0f, -1.0f));
}

// MARK: - Spherical Harmonics Evaluation

/// Evaluates spherical harmonics to compute view-dependent color.
/// - Parameters:
///   - dir: Normalized view direction vector (from camera to splat)
///   - sh0: DC term (raw SH band 0 coefficients, RGB)
///   - shCoeffs: Pointer to higher-order SH coefficients (can be null for degree 0)
///   - shDegree: The SH degree (0-3)
///   - splatIndex: Index of the splat (for computing offset into shCoeffs)
/// - Returns: Final RGB color after SH evaluation
inline half3 evaluateSH(float3 dir,
                        half3 sh0,
                        device const half* shCoeffs,
                        SHDegree shDegree,
                        uint splatIndex) {
    // Degree 0 (constant/ambient)
    float3 result = SH_C0 * float3(sh0);

    if (shDegree >= SHDegree1 && shCoeffs != nullptr) {
        float x = dir.x, y = dir.y, z = dir.z;

        // Calculate offset: SH1=3, SH2=8, SH3=15 coefficients (each is RGB triplet)
        uint coeffsPerSplat = (shDegree == SHDegree1) ? 3 :
                              (shDegree == SHDegree2) ? 8 : 15;
        device const packed_half3* sh = (device const packed_half3*)(shCoeffs + splatIndex * coeffsPerSplat * 3);

        // Degree 1: 3 basis functions
        result -= SH_C1 * y * float3(sh[0]);
        result += SH_C1 * z * float3(sh[1]);
        result -= SH_C1 * x * float3(sh[2]);

        if (shDegree >= SHDegree2) {
            float xx = x * x, yy = y * y, zz = z * z;
            float xy = x * y, yz = y * z, xz = x * z;
            float xxMinusYy = xx - yy;
            float xxPlusYy = xx + yy;

            // Degree 2: 5 basis functions
            result += SH_C2_0 * xy * float3(sh[3]);
            result += SH_C2_1 * yz * float3(sh[4]);
            result += SH_C2_2 * (2.0f * zz - xxPlusYy) * float3(sh[5]);
            result += SH_C2_3 * xz * float3(sh[6]);
            result += SH_C2_4 * xxMinusYy * float3(sh[7]);

            if (shDegree >= SHDegree3) {
                float zz4MinusXxYy = 4.0f * zz - xxPlusYy;

                // Degree 3: 7 basis functions
                result += SH_C3_0 * y * (3.0f * xx - yy) * float3(sh[8]);
                result += SH_C3_1 * xy * z * float3(sh[9]);
                result += SH_C3_2 * y * zz4MinusXxYy * float3(sh[10]);
                result += SH_C3_3 * z * (2.0f * zz - 3.0f * xxPlusYy) * float3(sh[11]);
                result += SH_C3_4 * x * zz4MinusXxYy * float3(sh[12]);
                result += SH_C3_5 * z * xxMinusYy * float3(sh[13]);
                result += SH_C3_6 * x * (xx - 3.0f * yy) * float3(sh[14]);
            }
        }
    }

    // Add 0.5 bias and clamp to non-negative (critical for correct colors)
    return half3(max(result + 0.5f, 0.0f));
}

// MARK: - Covariance Projection

float3 calcCovariance2D(float3 viewPos,
                        packed_half3 cov3Da,
                        packed_half3 cov3Db,
                        float4x4 viewMatrix,
                        float focalX,
                        float focalY,
                        float tanHalfFovX,
                        float tanHalfFovY) {
    float invViewPosZ = 1 / viewPos.z;
    float invViewPosZSquared = invViewPosZ * invViewPosZ;

    float limX = 1.3f * tanHalfFovX;
    float limY = 1.3f * tanHalfFovY;
    viewPos.x = clamp(viewPos.x * invViewPosZ, -limX, limX) * viewPos.z;
    viewPos.y = clamp(viewPos.y * invViewPosZ, -limY, limY) * viewPos.z;

    float3x3 J = float3x3(
        focalX * invViewPosZ, 0, 0,
        0, focalY * invViewPosZ, 0,
        -(focalX * viewPos.x) * invViewPosZSquared, -(focalY * viewPos.y) * invViewPosZSquared, 0
    );
    float3x3 W = float3x3(viewMatrix[0].xyz, viewMatrix[1].xyz, viewMatrix[2].xyz);
    float3x3 T = J * W;
    float3x3 Vrk = float3x3(
        cov3Da.x, cov3Da.y, cov3Da.z,
        cov3Da.y, cov3Db.x, cov3Db.y,
        cov3Da.z, cov3Db.y, cov3Db.z
    );
    float3x3 cov = T * Vrk * transpose(T);

    // Apply low-pass filter: every Gaussian should be at least
    // one pixel wide/high. Discard 3rd row and column.
    cov[0][0] += 0.3;
    cov[1][1] += 0.3;
    return float3(cov[0][0], cov[0][1], cov[1][1]);
}

// cov2D is a flattened 2d covariance matrix. Given
// covariance = | a b |
//              | c d |
// (where b == c because the Gaussian covariance matrix is symmetric),
// cov2D = ( a, b, d )
void decomposeCovariance(float3 cov2D, thread float2 &v1, thread float2 &v2) {
    float a = cov2D.x;
    float b = cov2D.y;
    float d = cov2D.z;
    float det = a * d - b * b; // matrix is symmetric, so "c" is same as "b"
    float trace = a + d;

    float mean = 0.5 * trace;
    float dist = max(0.1, sqrt(mean * mean - det)); // based on https://github.com/graphdeco-inria/diff-gaussian-rasterization/blob/main/cuda_rasterizer/forward.cu

    // Eigenvalues
    float lambda1 = mean + dist;
    float lambda2 = mean - dist;

    float2 eigenvector1;
    if (b == 0) {
        eigenvector1 = (a > d) ? float2(1, 0) : float2(0, 1);
    } else {
        eigenvector1 = normalize(float2(b, d - lambda2));
    }

    // Gaussian axes are orthogonal
    float2 eigenvector2 = float2(eigenvector1.y, -eigenvector1.x);

    v1 = eigenvector1 * sqrt(lambda1);
    v2 = eigenvector2 * sqrt(lambda2);
}

FragmentIn splatVertex(Splat splat,
                       Uniforms uniforms,
                       uint relativeVertexIndex,
                       device const half* shCoefficients,
                       SHDegree shDegree,
                       uint splatIndex) {
    FragmentIn out;

    applyReveal(splat, uniforms);
    if (uniforms.revealStyle == 5 && splat.color.a <= 0.0h) {
        out.position = float4(1, 1, 0, 1);
        return out;
    }
    applyPortal(splat, uniforms);
    applyArtwork(splat, uniforms);

    float4 viewPosition4 = uniforms.viewMatrix * float4(splat.position, 1);
    float3 viewPosition3 = viewPosition4.xyz;

    // Early cull: skip splats behind or at the camera plane
    // (In view space, camera looks down -z, so z >= 0 means behind camera)
    if (viewPosition3.z >= 0) {
        out.position = float4(1, 1, 0, 1);
        return out;
    }

    // Reject the same out-of-view centres before expensive SH/covariance work.
    float4 projectedCenter = uniforms.projectionMatrix * viewPosition4;

    float bounds = 1.2 * projectedCenter.w;
    if (projectedCenter.z < 0.0 ||
        projectedCenter.z > projectedCenter.w ||
        projectedCenter.x < -bounds ||
        projectedCenter.x > bounds ||
        projectedCenter.y < -bounds ||
        projectedCenter.y > bounds) {
        out.position = float4(1, 1, 0, 1);
        return out;
    }

    half3 srgbColor;
    if (shDegree == SHDegree0) {
        // Fast path for SH0
        srgbColor = half3(max(SH_C0 * float3(splat.color.rgb) + 0.5f, 0.0f));
    } else {
        float3 worldPosition = float3(splat.position);
        float3 viewDir = normalize(worldPosition - float3(uniforms.cameraPosition));
        srgbColor = evaluateSH(viewDir, splat.color.rgb, shCoefficients, shDegree, splatIndex);
    }

    float3 cov2D = calcCovariance2D(viewPosition3, splat.covA, splat.covB,
                                    uniforms.viewMatrix,
                                    uniforms.focalX, uniforms.focalY,
                                    uniforms.tanHalfFovX, uniforms.tanHalfFovY);

    float2 axis1;
    float2 axis2;
    decomposeCovariance(cov2D, axis1, axis2);

    const half2 relativeCoordinatesArray[] = { { -1, -1 }, { -1, 1 }, { 1, -1 }, { 1, 1 } };
    half2 relativeCoordinates = relativeCoordinatesArray[relativeVertexIndex];
    half2 screenSizeFloat = half2(uniforms.screenSize.x, uniforms.screenSize.y);
    half2 projectedScreenDelta =
        (relativeCoordinates.x * half2(axis1) + relativeCoordinates.y * half2(axis2))
        * 2
        * kBoundsRadius
        / screenSizeFloat;

    out.position = float4(projectedCenter.x + projectedScreenDelta.x * projectedCenter.w,
                          projectedCenter.y + projectedScreenDelta.y * projectedCenter.w,
                          projectedCenter.z,
                          projectedCenter.w);
    out.relativePosition = kBoundsRadius * relativeCoordinates;

    // Convert from sRGB to linear to match Metal expectations for shader color output
    out.color = half4(sRGBToLinear(srgbColor), splat.color.a);
    return out;
}

half splatFragmentAlpha(half2 relativePosition, half splatAlpha) {
    half negativeMagnitudeSquared = -dot(relativePosition, relativePosition);
    return (negativeMagnitudeSquared < -kBoundsRadiusSquared) ? 0 : exp(0.5 * negativeMagnitudeSquared) * splatAlpha;
}
