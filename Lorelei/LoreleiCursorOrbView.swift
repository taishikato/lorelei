//
//  LoreleiCursorOrbView.swift
//  Lorelei
//

import Combine
import SwiftUI

@MainActor
final class LoreleiCursorOrbModel: ObservableObject {
    @Published var position: CGPoint
    @Published var isVisible: Bool
    @Published var pulseTrigger: Int

    init(
        position: CGPoint = .zero,
        isVisible: Bool = false,
        pulseTrigger: Int = 0
    ) {
        self.position = position
        self.isVisible = isVisible
        self.pulseTrigger = pulseTrigger
    }
}

struct LoreleiCursorOrbView: View {
    @ObservedObject var model: LoreleiCursorOrbModel

    @State private var pulseScale: CGFloat = 1
    @State private var ringScale: CGFloat = 0.72
    @State private var ringOpacity: Double = 0
    @State private var lastPulseTrigger = 0

    private let coreDiameter: CGFloat = 26
    private let haloDiameter: CGFloat = 54

    var body: some View {
        ZStack {
            Color.black.opacity(0.001)

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 1, green: 0.67, blue: 0.29).opacity(0.36),
                                Color(red: 1, green: 0.43, blue: 0.04).opacity(0.18),
                                .clear
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: haloDiameter / 2
                        )
                    )
                    .frame(width: haloDiameter, height: haloDiameter)
                    .blur(radius: 7)

                Circle()
                    .stroke(Color(red: 1, green: 0.58, blue: 0.18).opacity(ringOpacity), lineWidth: 2)
                    .frame(width: coreDiameter, height: coreDiameter)
                    .scaleEffect(ringScale)
                    .blur(radius: 1.8)

                Circle()
                    .fill(
                        RadialGradient(
                            stops: [
                                .init(color: Color(red: 1, green: 0.96, blue: 0.82), location: 0),
                                .init(color: Color(red: 1, green: 0.73, blue: 0.34).opacity(0.95), location: 0.25),
                                .init(color: Color(red: 1, green: 0.62, blue: 0.24).opacity(0.82), location: 0.55),
                                .init(color: Color(red: 1, green: 0.37, blue: 0.04).opacity(0.34), location: 0.82),
                                .init(color: .clear, location: 1)
                            ],
                            center: UnitPoint(x: 0.34, y: 0.28),
                            startRadius: 0,
                            endRadius: coreDiameter / 2
                        )
                    )
                    .frame(width: coreDiameter, height: coreDiameter)
                    .shadow(color: Color(red: 1, green: 0.48, blue: 0.1).opacity(0.8), radius: 10)
                    .shadow(color: Color(red: 1, green: 0.3, blue: 0).opacity(0.36), radius: 20)
                    .scaleEffect(pulseScale)
            }
            .opacity(model.isVisible ? 1 : 0)
            .position(model.position)
            .animation(.easeInOut(duration: 0.15), value: model.isVisible)
            .onChange(of: model.pulseTrigger) { _, newValue in
                guard newValue != lastPulseTrigger else { return }
                lastPulseTrigger = newValue
                playPulse()
            }
        }
        .ignoresSafeArea()
    }

    private func playPulse() {
        ringScale = 0.72
        ringOpacity = 0.86

        withAnimation(.spring(response: 0.16, dampingFraction: 0.55)) {
            pulseScale = 0.82
        }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.62).delay(0.07)) {
            pulseScale = 1
        }
        withAnimation(.easeOut(duration: 0.28)) {
            ringScale = 2.2
            ringOpacity = 0
        }
    }
}
