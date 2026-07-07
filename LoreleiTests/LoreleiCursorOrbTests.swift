//
//  LoreleiCursorOrbTests.swift
//  LoreleiTests
//

import CoreGraphics
import Testing
@testable import Lorelei

struct LoreleiCursorOrbTests {
    @Test func appKitPointConvertsAXFrameCenterToBottomLeftOrigin() async throws {
        let point = LoreleiCursorOrbGeometry.appKitPoint(
            fromAXFrameCenter: CGRect(x: 100, y: 50, width: 20, height: 10),
            primaryScreenHeight: 1000
        )

        #expect(point == CGPoint(x: 110, y: 945))
    }

    @Test func appKitPointConvertsFrameNearTopOfScreen() async throws {
        let point = LoreleiCursorOrbGeometry.appKitPoint(
            fromAXFrameCenter: CGRect(x: 12, y: 0, width: 40, height: 20),
            primaryScreenHeight: 900
        )

        #expect(point == CGPoint(x: 32, y: 890))
    }

    @Test func appKitPointPreservesNegativeXOnSecondaryScreens() async throws {
        let point = LoreleiCursorOrbGeometry.appKitPoint(
            fromAXFrameCenter: CGRect(x: -220, y: 300, width: 60, height: 80),
            primaryScreenHeight: 1200
        )

        #expect(point == CGPoint(x: -190, y: 860))
    }

    @Test func travelDurationUsesFloorCeilingAndDistanceScale() async throws {
        #expect(LoreleiCursorOrbGeometry.travelDuration(from: .zero, to: .zero) == 0.18)
        #expect(LoreleiCursorOrbGeometry.travelDuration(from: .zero, to: CGPoint(x: 5000, y: 0)) == 0.45)
        #expect(LoreleiCursorOrbGeometry.travelDuration(from: .zero, to: CGPoint(x: 660, y: 0)) == 0.3)
    }

    @MainActor
    @Test func executorDoesNotVisualizeStaleElementLookup() async throws {
        let executor = AXDesktopActionExecutor()
        let visualizer = RecordingDesktopActionVisualizer()
        executor.visualizer = visualizer

        let outcome = await executor.perform(.press, elementID: "e99")

        #expect(outcome == DesktopActionOutcome(
            success: false,
            message: DesktopActionError.staleElementID("e99").toolMessage
        ))
        #expect(visualizer.animatedFrames.isEmpty)
    }
}

@MainActor
private final class RecordingDesktopActionVisualizer: DesktopActionVisualizing {
    var animatedFrames: [CGRect] = []

    func animateAction(toAXFrame frame: CGRect) async {
        animatedFrames.append(frame)
    }

    func concealForScreenshot() {}

    func revealAfterScreenshot() {}
}
