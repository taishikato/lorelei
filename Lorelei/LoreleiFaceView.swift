//
//  LoreleiFaceView.swift
//  Lorelei
//
//  Minimal vector face for the collapsed toolbar personality.
//

import SwiftUI

enum LoreleiFaceExpression: Equatable, Sendable {
    case neutral
    case listening
    case thinking
    case working
    case questioning
    case happy
    case sad

    static func expression(for runStatus: LoreleiRunStatus) -> LoreleiFaceExpression {
        switch runStatus {
        case .idle:
            .neutral
        case .listening:
            .listening
        case .transcribing:
            // Busy eyes looking around - the old .thinking arcs read as sad
            // at toolbar size and made STT/dictation progress look like failure.
            .working
        case .working:
            .working
        case .needsApproval:
            .questioning
        case .finished(let success):
            success ? .happy : .sad
        }
    }
}

struct LoreleiFaceView: View {
    let expression: LoreleiFaceExpression
    let audioLevel: CGFloat

    @State private var isBlinking = false
    @State private var workingLookOffset: CGFloat = -2.6

    var body: some View {
        ZStack {
            eyes
            mouth

            if expression == .questioning {
                questioningMark
            }
        }
        .foregroundStyle(faceTint)
        .frame(width: 54, height: 26)
        .drawingGroup()
        .task(id: expression) {
            isBlinking = false
            workingLookOffset = -2.6

            switch expression {
            case .neutral:
                await runBlinkLoop(intervalNanoseconds: 4_000_000_000)
            case .working:
                await runWorkingLoop()
            default:
                break
            }
        }
    }

    @ViewBuilder
    private var eyes: some View {
        switch expression {
        case .thinking:
            HStack(spacing: 16) {
                EyeArcShape(controlYOffset: 5)
                    .stroke(style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .frame(width: 10, height: 6)
                EyeArcShape(controlYOffset: 5)
                    .stroke(style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .frame(width: 10, height: 6)
            }
            .offset(y: -4)
        case .happy:
            HStack(spacing: 15) {
                EyeArcShape(controlYOffset: -5)
                    .stroke(style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .frame(width: 10, height: 7)
                EyeArcShape(controlYOffset: -5)
                    .stroke(style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .frame(width: 10, height: 7)
            }
            .offset(y: -4)
        case .sad:
            HStack(spacing: 15) {
                Capsule()
                    .frame(width: 10, height: 2)
                Capsule()
                    .frame(width: 10, height: 2)
            }
            .offset(y: -5)
        case .questioning:
            HStack(spacing: 15) {
                Capsule()
                    .frame(width: 8, height: 8)
                Capsule()
                    .frame(width: 8, height: 8)
            }
            .offset(y: -4)
            Capsule()
                .frame(width: 12, height: 2)
                .rotationEffect(.degrees(-13))
                .offset(x: -13, y: -13)
        default:
            HStack(spacing: expression == .listening ? 14 : 15) {
                eye
                eye
            }
            .offset(x: expression == .working ? workingLookOffset : 0, y: -5)
            .animation(.easeInOut(duration: 1.15), value: workingLookOffset)
        }
    }

    private var eye: some View {
        Capsule()
            .frame(
                width: expression == .listening ? 9 : 8,
                height: isBlinking ? 2 : (expression == .listening ? 10 : 8)
            )
            .animation(.easeInOut(duration: 0.12), value: isBlinking)
    }

    @ViewBuilder
    private var mouth: some View {
        switch expression {
        case .listening:
            ListeningMouthShape(openness: listeningMouthOpenness)
                .stroke(style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
                .frame(width: 20, height: 12)
                .offset(y: 6)
                .animation(.easeOut(duration: 0.08), value: listeningMouthOpenness)
        case .thinking:
            ThinkingMouthShape()
                .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 16, height: 4)
                .offset(y: 7)
        case .working:
            NeutralMouthShape()
                .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 16, height: 4)
                .offset(x: workingLookOffset * 0.25, y: 7)
                .animation(.easeInOut(duration: 1.15), value: workingLookOffset)
        case .questioning:
            NeutralMouthShape()
                .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 14, height: 4)
                .offset(y: 7)
        case .happy:
            SmileShape()
                .stroke(style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                .frame(width: 23, height: 11)
                .offset(y: 4)
        case .sad:
            SadMouthShape()
                .stroke(style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
                .frame(width: 22, height: 10)
                .offset(y: 8)
        case .neutral:
            NeutralMouthShape()
                .stroke(style: StrokeStyle(lineWidth: 2.1, lineCap: .round))
                .frame(width: 16, height: 4)
                .offset(y: 7)
        }
    }

    private var questioningMark: some View {
        Text("?")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .offset(x: 20, y: -8)
    }

    private var faceTint: Color {
        switch expression {
        case .questioning:
            .orange
        case .sad:
            .red
        default:
            .primary
        }
    }

    private var listeningMouthOpenness: CGFloat {
        min(max(audioLevel, 0), 1)
    }

    private func runBlinkLoop(intervalNanoseconds: UInt64) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
            guard !Task.isCancelled else { return }

            await blinkOnce()
        }
    }

    private func runWorkingLoop() async {
        var cycleCount = 0

        while !Task.isCancelled {
            withAnimation(.easeInOut(duration: 1.15)) {
                workingLookOffset = 2.6
            }
            try? await Task.sleep(nanoseconds: 1_150_000_000)
            guard !Task.isCancelled else { return }

            withAnimation(.easeInOut(duration: 1.15)) {
                workingLookOffset = -2.6
            }
            try? await Task.sleep(nanoseconds: 1_150_000_000)

            cycleCount += 1
            if cycleCount.isMultiple(of: 2) {
                await blinkOnce()
            }
        }
    }

    private func blinkOnce() async {
        withAnimation(.easeInOut(duration: 0.12)) {
            isBlinking = true
        }

        try? await Task.sleep(nanoseconds: 120_000_000)
        guard !Task.isCancelled else { return }

        withAnimation(.easeInOut(duration: 0.12)) {
            isBlinking = false
        }
    }
}

private struct EyeArcShape: Shape {
    let controlYOffset: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY),
            control: CGPoint(x: rect.midX, y: rect.midY + controlYOffset)
        )
        return path
    }
}

private struct NeutralMouthShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY),
            control: CGPoint(x: rect.midX, y: rect.midY + 1)
        )
        return path
    }
}

private struct ThinkingMouthShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY),
            control: CGPoint(x: rect.midX, y: rect.midY - 2)
        )
        return path
    }
}

private struct SmileShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + 1))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + 1),
            control: CGPoint(x: rect.midX, y: rect.maxY)
        )
        return path
    }
}

private struct SadMouthShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY - 1))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - 1),
            control: CGPoint(x: rect.midX, y: rect.minY)
        )
        return path
    }
}

private struct ListeningMouthShape: Shape {
    var openness: CGFloat

    var animatableData: CGFloat {
        get { openness }
        set { openness = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let clampedOpenness = min(max(openness, 0), 1)
        let widthInset = rect.width * (0.28 - (clampedOpenness * 0.12))
        let topY = rect.midY - 1 - (clampedOpenness * 2.5)
        let bottomY = rect.midY + 2 + (clampedOpenness * 4.5)
        let mouthRect = CGRect(
            x: rect.minX + widthInset,
            y: topY,
            width: rect.width - (widthInset * 2),
            height: max(3, bottomY - topY)
        )

        var path = Path()
        path.addEllipse(in: mouthRect)
        return path
    }
}
