//
//  Interactions.swift
//  binderBuilder
//
//  Small reusable bits of playfulness: a springy press style for card tiles, a
//  shimmer for loading placeholders, and a confetti burst for celebrations.
//

import SwiftUI

/// Card tiles/buttons spring slightly when pressed.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

/// A sweeping highlight, for loading placeholders.
private struct ShimmerModifier: ViewModifier {
    @State private var move = false
    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, .white.opacity(0.35), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.65)
                        .offset(x: move ? geo.size.width : -geo.size.width * 0.65)
                }
                .clipped()
                .allowsHitTesting(false)
            }
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { move = true }
            }
    }
}

extension View {
    func shimmering() -> some View { modifier(ShimmerModifier()) }
}

/// A one-shot confetti burst (place in an overlay; non-interactive).
struct ConfettiView: View {
    var count = 44
    @State private var animate = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(0..<count, id: \.self) { i in
                    ConfettiPiece(index: i, area: geo.size, animate: animate)
                }
            }
            .onAppear { animate = true }
        }
        .allowsHitTesting(false)
    }
}

private struct ConfettiPiece: View {
    let index: Int
    let area: CGSize
    let animate: Bool

    private let color: Color
    private let dx: CGFloat
    private let dy: CGFloat
    private let rotation: Double
    private let duration: Double

    init(index: Int, area: CGSize, animate: Bool) {
        self.index = index
        self.area = area
        self.animate = animate
        let colors: [Color] = [.red, .blue, .green, .yellow, .purple, .orange, .pink, .mint]
        color = colors[index % colors.count]
        dx = .random(in: -area.width / 2 ... area.width / 2)
        dy = .random(in: 0.2 ... 0.7) * area.height
        rotation = .random(in: 0 ... 720)
        duration = .random(in: 1.1 ... 2.0)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(color)
            .frame(width: 7, height: 10)
            .position(x: area.width / 2, y: area.height * 0.32)
            .offset(x: animate ? dx : 0, y: animate ? dy : 0)
            .rotationEffect(.degrees(animate ? rotation : 0))
            .opacity(animate ? 0 : 1)
            .animation(.easeOut(duration: duration).delay(Double(index) * 0.008), value: animate)
    }
}
