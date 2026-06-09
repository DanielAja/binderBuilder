//
//  MotionDebugOverlay.swift
//  binderBuilder
//
//  Small, semi-transparent debug control for SimulatedMotionProvider:
//  a ~120 pt joystick pad (drag = pitch/roll up to ±0.5 rad, springs back
//  to center on release) plus a Shake button. Self-contained — takes the
//  provider as a parameter and renders nothing scene-specific.
//
//  Intended integration (next phase), gated on the provider TYPE rather
//  than #if so it also appears with `-simulatedMotion` on device:
//
//      .overlay(alignment: .bottomTrailing) {
//          if let overlay = MotionDebugOverlay(anyProvider: motionProvider) {
//              overlay.padding()
//          }
//      }
//

import simd
import SwiftUI

struct MotionDebugOverlay: View {
    let provider: SimulatedMotionProvider

    init(provider: SimulatedMotionProvider) {
        self.provider = provider
    }

    /// Fails (returns nil) when the provider is not simulated, so call sites
    /// can gate on runtime type instead of build configuration.
    init?(anyProvider: any MotionProvider) {
        guard let simulated = anyProvider as? SimulatedMotionProvider else { return nil }
        self.provider = simulated
    }

    @State private var knobOffset: CGSize = .zero

    private let padDiameter: CGFloat = 120
    private let knobDiameter: CGFloat = 44
    /// Joystick range in radians: full deflection = ±0.5 rad pitch/roll.
    private let maxTilt: Float = 0.5

    var body: some View {
        VStack(spacing: 10) {
            joystick
            shakeButton
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .opacity(0.85)
    }

    // MARK: Joystick

    private var knobTravel: CGFloat { (padDiameter - knobDiameter) / 2 }

    private var joystick: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.25))
            Circle()
                .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
            Circle()
                .fill(Color.white.opacity(0.75))
                .frame(width: knobDiameter, height: knobDiameter)
                .offset(knobOffset)
        }
        .frame(width: padDiameter, height: padDiameter)
        .contentShape(Circle())
        .gesture(dragGesture)
        .accessibilityLabel("Tilt joystick")
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                var offset = value.translation
                let length = sqrt(offset.width * offset.width + offset.height * offset.height)
                if length > knobTravel, length > 0 {
                    offset.width *= knobTravel / length
                    offset.height *= knobTravel / length
                }
                knobOffset = offset
                // Drag up = positive pitch (top of device tips away);
                // drag right = positive roll.
                provider.setTargetTilt(
                    pitch: Float(-offset.height / knobTravel) * maxTilt,
                    roll: Float(offset.width / knobTravel) * maxTilt
                )
            }
            .onEnded { _ in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    knobOffset = .zero
                }
                provider.setTargetTilt(pitch: 0, roll: 0)
            }
    }

    // MARK: Shake

    private var shakeButton: some View {
        Button {
            provider.injectShake()
        } label: {
            Label("Shake", systemImage: "iphone.radiowaves.left.and.right")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.black.opacity(0.25)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.9))
        .accessibilityLabel("Inject shake")
    }
}

#Preview("Motion debug overlay") {
    ZStack(alignment: .bottomTrailing) {
        Color.indigo.ignoresSafeArea()
        MotionDebugOverlay(provider: SimulatedMotionProvider())
            .padding()
    }
}
