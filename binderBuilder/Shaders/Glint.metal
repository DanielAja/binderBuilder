//
//  Glint.metal
//  binderBuilder
//
//  The app's first SwiftUI [[stitchable]] shader: a diagonal specular band
//  that sweeps across a 2D view — the light-catch on a foil card as it turns
//  face up. Driven from UI/Components/GlintSweep.swift.
//
//  NOT a RealityKit shader. CardSurface.metal / PageCurl.metal are
//  CustomMaterial surface + geometry modifiers with entirely different entry
//  points and headers; nothing here is shared with them.
//
//  The band centre travels from -0.3 to 1.3 in normalized sweep space across
//  progress 0 -> 1, so the band starts and ends fully off-view for any width
//  up to 0.6.
//

#include <metal_stdlib>

using namespace metal;

/// Additive diagonal glint sweep. Alpha is preserved exactly, and the result
/// stays a valid premultiplied colour (never brighter than its own alpha).
///
/// - position:  pixel coordinate within the view (SwiftUI `colorEffect`).
/// - color:     premultiplied source pixel.
/// - size:      view size in points, used to normalize `position`.
/// - progress:  0...1 sweep parameter. Outside that range this is a no-op.
/// - bandWidth: band thickness in normalized sweep units (0.22 reads as a
///              highlight, above ~0.5 as a wash).
/// - tiltAngle: sweep direction in radians (0 sweeps left to right).
/// - tint:      band colour; its alpha scales peak intensity.
[[stitchable]] half4 glintSweep(float2 position, half4 color,
                                float2 size, float progress,
                                float bandWidth, float tiltAngle,
                                half4 tint)
{
    if (progress <= 0.0f || progress >= 1.0f) {
        return color;
    }

    const float2 uv = position / max(size, float2(1.0f));
    const float c = cos(tiltAngle);
    const float s = sin(tiltAngle);

    // Project uv onto the sweep axis, then remap the unit square's projection
    // range onto 0...1 so one sweep covers the whole view at any angle.
    const float projection = uv.x * c + uv.y * s;
    const float lowest = min(c, 0.0f) + min(s, 0.0f);
    const float extent = max(abs(c) + abs(s), 1e-4f);
    const float t = (projection - lowest) / extent;

    const float center = mix(-0.3f, 1.3f, progress);
    const float halfWidth = max(bandWidth, 1e-4f) * 0.5f;
    const float band = 1.0f - smoothstep(0.0f, 1.0f, abs(t - center) / halfWidth);

    // Scale by the destination alpha so transparent pixels stay transparent.
    const half gain = half(band) * tint.a * color.a;
    return half4(min(color.rgb + tint.rgb * gain, half3(color.a)), color.a);
}
