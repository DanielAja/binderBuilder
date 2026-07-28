//
//  GlintSweep.swift
//  binderBuilder
//
//  `glintSweep(progress:angle:width:)` — drives Shaders/Glint.metal as a
//  SwiftUI `colorEffect`, painting a diagonal specular band across a view.
//  Animate `progress` 0 -> 1 to sweep the band once, off-view to off-view.
//
//  The modifier is a strict no-op at `progress == 0`, so a reveal can leave it
//  attached for the whole beat and pay nothing until the glint fires.
//

import SwiftUI

extension View {
    /// Sweeps a specular band across this view.
    ///
    /// - Parameters:
    ///   - progress: 0...1 position of the band. 0 renders nothing at all.
    ///   - angle: sweep direction; the default leans the band like light off a
    ///     card held slightly off-square.
    ///   - width: band thickness as a fraction of the sweep axis.
    func glintSweep(
        progress: Double,
        angle: Angle = .degrees(22),
        width: Double = 0.22
    ) -> some View {
        modifier(GlintSweepModifier(progress: progress, angle: angle, width: width))
    }
}

private struct GlintSweepModifier: ViewModifier {
    let progress: Double
    let angle: Angle
    let width: Double

    /// Opaque so the shader's `tint.a` is unambiguous; the slightly warm,
    /// sub-white RGB keeps the band from clipping to flat white.
    private static let tint = Color(.sRGB, red: 0.96, green: 0.94, blue: 0.87, opacity: 1)

    @ViewBuilder func body(content: Content) -> some View {
        if progress <= 0 {
            content
        } else {
            content.visualEffect { view, proxy in
                view.colorEffect(
                    ShaderLibrary.glintSweep(
                        .float2(proxy.size),
                        .float(Float(progress)),
                        .float(Float(width)),
                        .float(Float(angle.radians)),
                        .color(Self.tint)
                    )
                )
            }
        }
    }
}
